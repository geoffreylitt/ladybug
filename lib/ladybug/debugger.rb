require 'memoist'
require 'binding_of_caller'

module Ladybug
  # manages multiple debug sessions
  # (todo: better name?)
  class Debugger
    def initialize
      @sessions = []
    end

    def new_session
      debug_session = DebugSession.new
      @sessions << debug_session
      debug_session
    end

    def retro_eval(expr)
      output = ""
      @sessions.each do |session|
        output += "#{session.id}\n"
        session.watchpoints.each do |watchpoint|
          output += "#{watchpoint[:binding].eval(expr)}\n"
        end
        output += "\n"
      end

      output
    end

    attr_accessor :sessions
  end

  class DebugSession
    def initialize
      @id = SecureRandom.uuid
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

    attr_accessor :watchpoints, :id
  end
end
