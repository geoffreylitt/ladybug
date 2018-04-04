require 'memoist'
require 'binding_of_caller'

module Ladybug
  # A unique-ish random ID (short is nice for debugging)
  def self.random_id
    SecureRandom.hex(10)
  end

  # manages multiple debug sessions
  # (todo: better name?)
  class Debugger
    def initialize
      @sessions = []

      # default trace callback: just print
      @on_trace_callback = -> (trace) { puts trace[:result] }

      @session_id = 1
    end

    def on_trace(&block)
      @on_trace_callback = block
    end

    def new_session
      debug_session = Session.new(parent: self)
      @sessions << debug_session
      debug_session
    end

    def retro_eval(expression)
      output = ""
      @sessions.each do |session|
        output += "#{session.id}\n"
        session.retro_eval(expression).each do |result|
          output += "\t#{result[:location].path}:#{result[:location].lineno} / #{result[:result]}\n"
        end
        output += "\n"
      end

      output
    end

    attr_accessor :sessions, :on_trace_callback
  end

  # A single run of the program, delimited by the user calling new_session
  class Session
    def initialize(parent:)
      @id = Ladybug.random_id
      @traces = []
      @parent = parent
      @watchpoints = []
    end

    def retro_eval(expression)
      traces.map do |trace|
        {
          id: trace[:id],
          location: trace[:location],
          result: trace[:binding].eval(expression),
        }
      end
    end

    def debug(expression)
      caller_location = Thread.current.backtrace_locations[2]

      watchpoint = @watchpoints.find { |w| w.location.to_s == caller_location.to_s } ||
                   Watchpoint.new(location: caller_location )
      @watchpoints << watchpoint

      # The trace as a hash, containing rich objects not serialized yet
      trace = {
        id: Ladybug.random_id,
        session: self,
        binding: binding.of_caller(1),
        watchpoint: watchpoint,
        result: expression
      }

      parent.on_trace_callback.call(trace)
      @traces << trace
    end

    attr_accessor :traces, :id, :parent
  end

  # A point where the user has put a debug statement
  class Watchpoint
    def initialize(location:)
      @id = Ladybug.random_id
      @location = location
    end

    attr_accessor :id, :location
  end
end
