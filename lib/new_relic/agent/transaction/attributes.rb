# encoding: utf-8
# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/rpm/blob/master/LICENSE for complete details.

module NewRelic
  module Agent
    class Transaction
      class Attributes
        include Coerce

        KEY_LIMIT   = 255
        VALUE_LIMIT = 255
        COUNT_LIMIT = 64

        EMPTY_HASH = {}.freeze

        CAN_BYTESLICE = String.instance_methods.include?(:byteslice)

        def initialize(filter)
          @filter = filter

          @custom_attributes = {}
          @agent_attributes = {}
          @intrinsic_attributes = {}

          @custom_destinations = {}
          @agent_destinations = {}
        end

        def add_custom_attribute(key, value)
          if @custom_attributes.size >= COUNT_LIMIT
            unless @already_warned_count_limit
              NewRelic::Agent.logger.warn("Custom attributes count exceeded limit of #{COUNT_LIMIT}. Any additional custom attributes during this transaction will be dropped.")
              @already_warned_count_limit = true
            end
            return
          end

          if exceeds_bytesize_limit?(key, KEY_LIMIT)
            NewRelic::Agent.logger.warn("Custom attribute key '#{key}' was longer than limit of #{KEY_LIMIT} bytes. This attribute will be dropped.")
            return
          end

          destinations = @filter.apply(key, AttributeFilter::DST_ALL)
          return if destinations == AttributeFilter::DST_NONE

          @custom_destinations[key] = destinations
          add(@custom_attributes, key, value)
        end

        def add_agent_attribute(key, value, default_destinations)
          destinations = @filter.apply(key, default_destinations)
          return if destinations == AttributeFilter::DST_NONE

          @agent_destinations[key] = destinations
          add(@agent_attributes, key, value)
        end

        def add_intrinsic_attribute(key, value)
          add(@intrinsic_attributes, key, value)
        end

        def merge_custom_attributes(other)
          other.each do |key, value|
            self.add_custom_attribute(key, value)
          end
        end

        def merge_request_parameters(params)
          flatten_and_coerce(params, "request.parameters").each do |k, v|
            add_agent_attribute(k, v, AttributeFilter::DST_NONE)
          end
        end

        def custom_attributes_for(destination)
          for_destination(@custom_attributes, @custom_destinations, destination)
        end

        def agent_attributes_for(destination)
          for_destination(@agent_attributes, @agent_destinations, destination)
        end

        def intrinsic_attributes_for(destination)
          if destination == NewRelic::Agent::AttributeFilter::DST_TRANSACTION_TRACER ||
             destination == NewRelic::Agent::AttributeFilter::DST_ERROR_COLLECTOR
            @intrinsic_attributes
          else
            EMPTY_HASH
          end
        end

        private

        def add(attributes, key, value)
          if exceeds_bytesize_limit?(value, VALUE_LIMIT)
            value = slice(value)
          end

          attributes[key] = value
        end

        def for_destination(attributes, calculated_destinations, destination)
          return attributes.dup if destination == NewRelic::Agent::AttributeFilter::DST_DEVELOPER_MODE

          attributes.inject({}) do |memo, (key, value)|
            if @filter.allows?(calculated_destinations[key], destination)
              memo[key] = value
            end
            memo
          end
        end

        def exceeds_bytesize_limit?(value, limit)
          if value.respond_to?(:bytesize)
            value.bytesize > limit
          elsif value.is_a?(Symbol)
            value.to_s.bytesize > limit
          else
            false
          end
        end

        # Take one byte past our limit. Why? This lets us unconditionally chop!
        # the end. It'll either remove the one-character-too-many we have, or
        # peel off the partial, mangled character left by the byteslice.
        def slice(incoming)
          if CAN_BYTESLICE
            result = incoming.to_s.byteslice(0, VALUE_LIMIT + 1)
          else
            # < 1.9.3 doesn't have byteslice, so we take off bytes instead.
            result = incoming.to_s.bytes.take(VALUE_LIMIT + 1).pack("C*")
          end

          result.chop!
          result
        end

        def flatten_and_coerce(params, prefix, result = {})
          case params
          when Hash
            params.each do |key, val|
              normalized_key = EncodingNormalizer.normalize_string(key.to_s)
              flatten_and_coerce(val, "#{prefix}.#{normalized_key}", result)
            end
          when Array
            params.each_with_index do |val, idx|
              flatten_and_coerce(val, "#{prefix}.#{idx}", result)
            end
          else
            result[prefix] = scalar(params)
          end
          result
        end
      end
    end
  end
end
