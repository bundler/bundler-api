require 'pathname'

module BundlerApi
  class GemStorage
    def initialize(folder)
      fail "Folder #{folder} does not exist or is not writable" unless File.writable?(folder)
      @folder = Pathname.new(folder)
    end

    def get(name)
      CachedGemFile.new(@folder, name)
    end
  end

  class CachedGemFile
    def initialize(folder, name)
      @folder = folder.join(File.basename(name))
      @name = name
    end

    def save(headers, content)
      Dir.mkdir(@folder) unless Dir.exist?(@folder)
      File.open(headers_path, 'w') {|f| f.write(headers.to_yaml) }
      File.open(content_path, 'w') {|f| f.write(content) }
      @headers = headers
      @content = content
    end

    def exist?
      content_path.exist? && headers_path.exist?
    end

    def content
      load
      @content
    end

    def headers
      load
      @headers
    end

    private

    def load
      return unless @content.nil? and @headers.nil?
      fail "#{@name} does not exiat" unless exist?
      @headers = File.open(headers_path) {|f| YAML.load(f.read) }
      @content = File.open(content_path) {|f| f.read }
    end

    def content_path
      @folder.join(@name)
    end

    def headers_path
      @folder.join("headers.yaml")
    end
  end
end
