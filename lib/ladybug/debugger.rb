require 'memoist'

module Ladybug
  # manages multiple debug sessions
  # (todo: better name?)
  class Debugger
    def start_session
      debug_session = DebugSession.new
      @sessions << debug_session
      yield debug_session
    end
  end

  class DebugSession
    def initialize(parent:)
      @parent = parent
    end

    def debug(expression)
      puts "debug: #{expression.to_s}"
    end
  end
end
