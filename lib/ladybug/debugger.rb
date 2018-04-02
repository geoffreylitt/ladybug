require 'memoist'
require 'binding_of_caller'

module Ladybug
  # manages multiple debug sessions
  # (todo: better name?)
  class Debugger
    def initialize
      @sessions = []
    end

    # Might be able to change this from yielding to just returning
    def start_session
      debug_session = DebugSession.new
      @sessions << debug_session
      yield debug_session
    end
  end

  class DebugSession
    def initialize
      @watchpoints = []
    end

    def debug(expression)
      caller_binding = binding.of_caller(1)
      caller_location = Thread.current.backtrace_locations[2]

      puts "debug: #{expression}"

      @watchpoints << {
        id: SecureRandom.uuid,
        binding: caller_binding,
        location: caller_location,
        expression: expression
      }
    end
  end
end
