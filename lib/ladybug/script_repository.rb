# A repository of the source files for the app.
# The Chrome Devtools API switches back and forth between different
# references to a source file; this repository enables lookup by
# different attributes and conversion between them.

module Ladybug
  class ScriptRepository
    # todo: would be nice to dynamically set this to the server name
    ROOT_URL = "http://localhost"

    # todo: accept path as param?
    def initialize
      @scripts = enumerate_scripts
    end

    def all
      @scripts
    end

    def find(args)
      @scripts.find do |script|
        args.all? do |key, value|
          script[key] == value
        end
      end
    end

    private

    # Return a list of Scripts with all attributes populated
    def enumerate_scripts
      Dir.glob("**/*").
        reject { |f| File.directory?(f) }.
        select { |f| File.extname(f) == ".rb" }.
        map do |filename|
          stat = File.stat(filename)

          OpenStruct.new(
            id: SecureRandom.uuid,
            path: filename,
            absolute_path: File.expand_path(filename),
            virtual_url: "#{ROOT_URL}/#{filename}",
            size: stat.size,
            last_modified_time: stat.mtime
          )
        end
    end
  end
end

