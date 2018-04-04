require 'memoist'
require 'binding_of_caller'

module Ladybug
  # manages multiple debug sessions
  # (todo: better name?)
  class Debugger
    def initialize
      @sessions = []

      # default trace callback: just print
      @on_trace_callback = -> (trace) { puts trace[:result] }
    end

    def on_trace(&block)
      @on_trace_callback = block
    end

    def new_session
      debug_session = DebugSession.new(parent: self)
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

  class DebugSession
    def initialize(parent:)
      @id = SecureRandom.uuid
      @traces = []
      @parent = parent
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
      trace = {
        id: SecureRandom.uuid,
        binding: binding.of_caller(1),
        location: Thread.current.backtrace_locations[2],
        result: expression
      }

      parent.on_trace_callback.call(trace)
      @traces << trace
    end

    attr_accessor :traces, :id, :parent
  end
end
