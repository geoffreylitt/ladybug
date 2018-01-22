module Ladybug
  # This class:
  #
  # * serializes objects for display in the Chrome UI
  # * maintains references to all objects for which it has given out IDs for;
  #   this ensures they don't get GC'd and can be dereferenced later by ID.
  #
  # TODO: Handle Chrome's "release" APIs to enable releasing references
  #       at some point and avoid too much memory growth

  class ObjectManager
    def initialize
      @objects = {}
    end

    # Given an ID, return the object from our registry
    def find(id)
      @objects[id]
    end

    # Given an object, register it in our internal state and
    # return an ID for it
    def register(object)
      object_id = SecureRandom.uuid
      @objects[object_id] = object
      object_id
    end

    # Convert a Ruby object to a hash representing a Chrome RemoteObject
    # https://chromedevtools.github.io/devtools-protocol/tot/Runtime#type-RemoteObject
    def serialize(object)
      case object
      when String
        {
          type: "string",
          value: object,
          description: object
        }
      when Numeric
        {
          type: "number",
          value: object,
          description: object.to_s
        }
      when TrueClass, FalseClass
        {
          type: "boolean",
          value: object,
          description: object.to_s
        }
      when Symbol
        {
          type: "symbol",
          value: object,
          description: object.to_s
        }
      when Array
        result = {
          type: "object",
          className: object.class.to_s,
          description: "Array(#{object.length})",
          objectId: register(object),
          subtype: "array"
        }

        result.merge!(
          preview: result.merge(
            overflow: false,
            properties: get_properties(object)
          )
        )

        result
      when nil
        {
          type: "object",
          subtype: "null",
          value: nil
        }
      else
        {
          type: "object",
          className: object.class.to_s,
          description: object.to_s,
          objectId: register(object)
        }
      end
    end

    # Ruby objects don't have properties like JS objects do,
    # so we need to figure out the best properties to show for non-primitives.
    #
    # We first give the object a chance to tell us its debug properties,
    # then we fall back to handling a bunch of common cases,
    # then finally we give up and just serialize its instance variables.
    def get_properties(object)
      if object.respond_to?(:chrome_debug_properties)
        get_properties(object.chrome_debug_properties)
      elsif object.is_a? Hash
        object.
          map do |key, value|
            kv = {
              name: key,
              value: serialize(value)
            }

            kv
          end.
          reject { |property| property[:value].nil? }
      elsif object.is_a? Array
        object.map.with_index do |element, index|
          {
            name: index.to_s,
            value: serialize(element)
          }
        end

      # TODO: This section is too magical,
      # better to let users just define their own chrome_debug_properties
      # and then add an optional Rails plugin to the gem which
      # monkey patches rails classes.
      elsif object.respond_to?(:to_a)
        get_properties(object.to_a)
      elsif object.respond_to?(:attributes)
        get_properties(object.attributes)
      elsif object.respond_to?(:to_hash)
        get_properties(object.to_hash)
      elsif object.respond_to?(:to_h)
        get_properties(object.to_h)
      else
        ivar_hash = object.instance_variables.each_with_object({}) do |ivar, hash|
          hash[ivar] = object.instance_variable_get(ivar)
        end

        get_properties(ivar_hash)
      end
    end
  end
end
