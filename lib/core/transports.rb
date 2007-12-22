require "cgi"
require "net/http"
require "net/ssh"
require "net/sftp"
require "uri"
require "uri/sftp"
require "digest/md5"
require "digest/sha1"
require "facet/progressbar"
require "highline"
require "tempfile"
require "uri/sftp"


# Monkeypatching: SFTP never defines the mkdir method on its session or the underlying
# driver, it just redirect calls through method_missing. Rake, on the other hand, decides
# to define mkdir on Object, and so routes our calls to FileUtils.
module Net #:nodoc:all
  class Session
    def mkdir(path, attrs = {})
      method_missing :mkdir, path, attrs
    end
  end

  class SFTP::Protocol::Driver
    def mkdir(first, path, attrs = {})
      method_missing :mkdir, first, path, attrs
    end
  end
end


# Not quite open-uri, but similar. Provides read and write methods for the resource represented by the URI.
# Currently supports reads for URI::HTTP and writes for URI::SFTP. Also provides convenience methods for
# downloads and uploads.
module URI

  # Raised when trying to read/download a resource that doesn't exist.
  class NotFoundError < RuntimeError
  end

  class << self

    # :call-seq:
    #   read(uri, options?) => content
    #   read(uri, options?) { |chunk| ... }
    #
    # Reads from the resource behind this URI. The first form returns the content of the resource,
    # the second form yields to the block with each chunk of content (usually more than one).
    #
    # For example:
    #   File.open "image.jpg", "w" do |file|
    #     URI.read("http://example.com/image.jpg") { |chunk| file.write chunk }
    #   end
    # Shorter version:
    #   File.open("image.jpg", "w") { |file| file.write URI.read("http://example.com/image.jpg") }
    #
    # Supported options:
    # * :modified -- Only download if file modified since this timestamp. Returns nil if not modified.
    # * :progress -- Show the progress bar while reading.
    def read(uri, options = nil, &block)
      uri = URI.parse(uri.to_s) unless URI === uri
      uri.read options, &block
    end

    # :call-seq:
    #   download(uri, target, options?)
    #
    # Downloads the resource to the target.
    #
    # The target may be a file name (string or task), in which case the file is created from the resource.
    # The target may also be any object that responds to +write+, e.g. File, StringIO, Pipe.
    #
    # Use the progress bar when running in verbose mode.
    def download(uri, target, options = nil)
      uri = URI.parse(uri.to_s) unless URI === uri
      uri.download target, options
    end
      
    # :call-seq:
    #   write(uri, content, options?)
    #   write(uri, options?) { |bytes| .. }
    #
    # Writes to the resource behind the URI. The first form writes the content from a string or an object
    # that responds to +read+ and optionally +size+. The second form writes the content by yielding to the
    # block. Each yield should return up to the specified number of bytes, the last yield returns nil.
    #
    # For example:
    #   File.open "killer-app.jar", "rb" do |file|
    #     write("sftp://localhost/jars/killer-app.jar") { |chunk| file.read(chunk) }
    #   end
    # Or:
    #   write "sftp://localhost/jars/killer-app.jar", File.read("killer-app.jar")
    #
    # Supported options:
    # * :progress -- Show the progress bar while reading.
    def write(uri, *args, &block)
      uri = URI.parse(uri.to_s) unless URI === uri
      uri.write *args, &block
    end
      
    # :call-seq:
    #   upload(uri, source, options?)
    #
    # Uploads from source to the resource.
    #
    # The source may be a file name (string or task), in which case the file is uploaded to the resource.
    # The source may also be any object that responds to +read+ (and optionally +size+), e.g. File, StringIO, Pipe.
    #
    # Use the progress bar when running in verbose mode.
    def upload(uri, source, options = nil)
      uri = URI.parse(uri.to_s) unless URI === uri
      uri.upload source, options
    end

  end

  class Generic

    # :call-seq:
    #   read(options?) => content
    #   read(options?) { |chunk| ... }
    #
    # Reads from the resource behind this URI. The first form returns the content of the resource,
    # the second form yields to the block with each chunk of content (usually more than one).
    #
    # For options, see URI::read.
    def read(options = nil, &block)
      fail "This protocol doesn't support reading (yet, how about helping by implementing it?)"
    end

    # :call-seq:
    #   download(target, options?)
    #
    # Downloads the resource to the target.
    #
    # The target may be a file name (string or task), in which case the file is created from the resource.
    # The target may also be any object that responds to +write+, e.g. File, StringIO, Pipe.
    #
    # Use the progress bar when running in verbose mode.
    def download(target, options = nil)
      case target
      when Rake::Task
        download target.name, options
      when String
        # If download breaks we end up with a partial file which is
        # worse than not having a file at all, so download to temporary
        # file and then move over.
        modified = File.stat(target).mtime if File.exist?(target)
        temp = nil
        Tempfile.open File.basename(target) do |temp|
          temp.binmode
          read({:progress=>verbose}.merge(options || {}).merge(:modified=>modified)) { |chunk| temp.write chunk }
        end
        mkpath File.dirname(target)
        File.move temp.path, target
      when File
        read({:progress=>verbose}.merge(options || {}).merge(:modified=>target.mtime)) { |chunk| target.write chunk }
        target.flush
      else
        raise ArgumentError, "Expecting a target that is either a file name (string, task) or object that responds to write (file, pipe)." unless target.respond_to?(:write)
        read({:progress=>verbose}.merge(options || {})) { |chunk| target.write chunk }
        target.flush
      end
    end
    
    # :call-seq:
    #   write(content, options?)
    #   write(options?) { |bytes| .. }
    #
    # Writes to the resource behind the URI. The first form writes the content from a string or an object
    # that responds to +read+ and optionally +size+. The second form writes the content by yielding to the
    # block. Each yield should return up to the specified number of bytes, the last yield returns nil.
    #
    # For options, see URI::write.
    def write(*args, &block)
      options = args.pop if Hash === args.last
      options ||= {}
      if String === args.first
        ios = StringIO.new(args.first, "r")
        write(options.merge(:size=>args.first.size)) { |bytes| ios.read(bytes) }
      elsif args.first.respond_to?(:read)
        size = args.first.size rescue nil
        write({:size=>size}.merge(options)) { |bytes| args.first.read(bytes) }
      elsif args.empty? && block
        write_internal options, &block
      else
        raise ArgumentError, "Either give me the content, or pass me a block, otherwise what would I upload?"
      end
    end

    # :call-seq:
    #   upload(source, options?)
    #
    # Uploads from source to the resource.
    #
    # The source may be a file name (string or task), in which case the file is uploaded to the resource.
    # If the source is a directory, uploads all files inside the directory (including nested directories).
    # The source may also be any object that responds to +read+ (and optionally +size+), e.g. File, StringIO, Pipe.
    #
    # Use the progress bar when running in verbose mode.
    def upload(source, options = nil)
      source = source.name if Rake::Task === source
      options ||= {}
      if String === source
        raise NotFoundError, "No source file/directory to upload." unless File.exist?(source)
        if File.directory?(source)
          Dir.glob("#{source}/**/*").reject { |file| File.directory?(file) }.each do |file|
            uri = self + (File.join(self.path, file.sub(source, "")))
            uri.upload file, {:digests=>[]}.merge(options)
          end
        else
          File.open(source, "rb") { |input| upload input, options }
        end
      elsif source.respond_to?(:read)
        digests = (options[:digests] || [:md5, :sha1]).
          inject({}) { |hash, name| hash[name] = Digest.const_get(name.to_s.upcase).new ; hash }
        size = source.size rescue nil
        write (options).merge(:progress=>verbose && size, :size=>size) do |bytes|
          source.read(bytes).tap do |chunk|
            digests.values.each { |digest| digest << chunk } if chunk
          end
        end
        digests.each do |key, digest|
          self.merge("#{self.path}.#{key}").write "#{digest.hexdigest} #{File.basename(path)}",
            (options).merge(:progress=>false)
        end
      else
        raise ArgumentError, "Expecting source to be a file name (string, task) or any object that responds to read (file, pipe)."
      end
    end

  protected

    # :call-seq:
    #   with_progress_bar(enable, file_name, size) { |progress| ... }
    #
    # Displays a progress bar while executing the block. The first argument must be true for the
    # progress bar to show (TTY output also required), as a convenient for selectively using the
    # progress bar from a single block.
    #
    # The second argument provides a filename to display, the third its size in bytes.
    #
    # The block is yielded with a progress object that implements a single method.
    # Call << for each block of bytes down/uploaded.
    def with_progress_bar(enable, file_name, size) #:nodoc:
      if enable && $stdout.isatty
        progress_bar = Console::ProgressBar.new(file_name, size)
        # Extend the progress bar so we can display count/total.
        class << progress_bar
          def total()
            convert_bytes(@total)
          end
        end
        # Squeeze the filename into 30 characters.
        if file_name.size > 30
          base, ext = file_name.split(".")
          truncated = "#{base[0..26-ext.to_s.size]}...#{ext}"
        else
          truncated = file_name
        end
        progress_bar.format = "#{truncated}: %3d%% %s %s/%s %s"
        progress_bar.format = "%3d%% %s %s/%s %s"
        progress_bar.format_arguments = [:percentage, :bar, :bytes, :total, :stat]
        progress_bar.bar_mark = "."

        begin
          class << progress_bar
            def <<(bytes)
              inc bytes.respond_to?(:size) ? bytes.size : bytes
            end
          end
          yield progress_bar
        ensure
          progress_bar.finish
        end
      else
        progress_bar = Object.new
        class << progress_bar
          def <<(bytes)
          end
        end
        yield progress_bar
      end
    end

    # :call-seq:
    #   proxy_uri() => URI?
    #
    # Returns the proxy server to use. Obtains the proxy from the relevant environment variable (e.g. HTTP_PROXY).
    # Supports exclusions based on host name and port number from environment variable NO_PROXY.
    def proxy_uri()
      proxy = ENV["#{scheme.upcase}_PROXY"]
      proxy = URI.parse(proxy) if String === proxy
      excludes = (ENV["NO_PROXY"] || "").split(/\s*,\s*/).compact
      excludes = excludes.map { |exclude| exclude =~ /:\d+$/ ? exclude : "#{exclude}:*" }
      return proxy unless excludes.any? { |exclude| File.fnmatch(exclude, "#{host}:#{port}") }
    end

    def write_internal(options, &block) #:nodoc:
      fail "This protocol doesn't support writing (yet, how about helping by implementing it?)"
    end

  end


  class HTTP #:nodoc:

    # See URI::Generic#read
    def read(options = nil, &block)
      options ||= {}

      headers = { "If-Modified-Since" => CGI.rfc1123_date(options[:modified].utc) } if options[:modified]
      result = nil
      request = lambda do |http|
        puts "Requesting #{self}"  if Rake.application.options.trace
        http.request_get(path, headers) do |response|
          case response
          when Net::HTTPNotModified
            # No modification, nothing to do.
            puts "Not modified since last download" if Rake.application.options.trace

          when Net::HTTPRedirection
            # Try to download from the new URI, handle relative redirects.
            puts "Redirected to #{response['Location']}" if Rake.application.options.trace
            result = (self + URI.parse(response["location"])).read(options, &block)

          when Net::HTTPOK
            puts "Downloading #{self}" if verbose
            with_progress_bar options[:progress], path.split("/").last, response.content_length do |progress|
              if block
                response.read_body do |chunk|
                  block.call chunk
                  progress << chunk
                end
              else
                result = ""
                response.read_body do |chunk|
                  result << chunk
                  progress << chunk
                end
              end
            end

          when Net::HTTPNotFound
            raise NotFoundError, "Looking for #{self} and all I got was a 404!"
          else
            raise RuntimeError, "Failed to download #{self}: #{response.message}"
          end
        end
      end

      if proxy = proxy_uri
        proxy = URI.parse(proxy) if String === proxy
        Net::HTTP.start(host, port, proxy.host, proxy.port, proxy.user, proxy.password) { |http| request[http] }
      else
        Net::HTTP.start(host, port) { |http| request[http] }
      end
      result
    end

  end


  class SFTP #:nodoc:

    class << self
      # Caching of passwords, so we only need to ask once.
      def passwords()
        @passwords ||= {}
      end
    end

  protected

    def write_internal(options, &block) #:nodoc:
      # SSH options are based on the username/password from the URI.
      ssh_options = { :port=>port, :username=>user }.merge(options[:ssh_options] || {})
      ssh_options[:password] ||= SFTP.passwords[host]
      begin
        puts "Connecting to #{host}" if Rake.application.options.trace
        session = Net::SSH.start(host, ssh_options)
        SFTP.passwords[host] = ssh_options[:password]
      rescue Net::SSH::AuthenticationFailed=>ex
        # Only if running with console, prompt for password.
        if !ssh_options[:password] && $stdout.isatty
          password = HighLine.new.ask("Password for #{host}:") { |q| q.echo = "*" }
          ssh_options[:password] = password
          retry
        end
        raise
      end

      session.sftp.connect do |sftp|
        puts "connected" if Rake.application.options.trace

        # To create a path, we need to create all its parent. We use realpath to determine if
        # the path already exists, otherwise mkdir fails.
        puts "Creating path #{@base_path}" if Rake.application.options.trace
        File.dirname(path).split("/").inject("") do |base, part|
          combined = base + part
          sftp.realpath combined rescue sftp.mkdir combined, {}
          "#{combined}/"
        end

        with_progress_bar options[:progress] && options[:size], path.split("/"), options[:size] || 0 do |progress|
          puts "Uploading to #{path}" if Rake.application.options.trace
          sftp.open_handle(path, "w") do |handle|
            # Writing in chunks gives us the benefit of a progress bar,
            # but also require that we maintain a position in the file,
            # since write() with two arguments always writes at position 0.
            pos = 0
            while chunk = yield(32 * 4096)
              sftp.write(handle, chunk, pos)
              pos += chunk.size
              progress << chunk
            end
            sftp.setstat(path, :permissions => options[:permissions]) if options[:permissions]
          end
        end
      end
    end

  end


  # File URL. Keep in mind that file URLs take the form of <code>file://host/path</code>, although the host
  # is not used, so typically all you will see are three backslashes. This methods accept common variants,
  # like <code>file:/path</code> but always returns a valid URL.
  class FILE < Generic

    COMPONENT = [ :host, :path ].freeze

    def initialize(*args)
      super
      # file:something (opaque) becomes file:///something
      if path.nil?
        set_path "/#{opaque}"
        unless opaque.nil?
          set_opaque nil
          warn "#{caller[2]}: We'll accept this URL, but just so you know, it needs three slashes, as in: #{to_s}"
        end
      end
      # Sadly, file://something really means file://something/ (something being server)
      set_path "/" if path.empty?

      # On windows, file://c:/something is not a valid URL, but people do it anyway, so if we see a drive-as-host,
      # we'll just be nice enough to fix it. (URI actually strips the colon here)
      if host =~ /^[a-zA-Z]$/
        set_path "/#{host}:#{path}"
        set_host nil
      end
    end

    # See URI::Generic#read
    def read(options = nil, &block)
      options ||= {}
      raise ArgumentError, "Either you're attempting to read a file from another host (which we don't support), or you used two slashes by mistake, where you should have file:///<path>." unless host.blank?

      path = real_path
      # TODO: complain about clunky URLs
      raise NotFoundError, "Looking for #{self} and can't find it." unless File.exists?(path)
      raise NotFoundError, "Looking for the file #{self}, and it happens to be a directory." if File.directory?(path)
      File.open path, "rb" do |input|
        with_progress_bar options[:progress], path.split("/").last, input.stat.size do |progress|
          block ? block.call(input.read) : input.read
        end
      end
    end

    def to_s()
      "file://#{host}#{path}"
    end

    # The URL path always starts with a backslash. On most operating systems (Linux, Darwin, BSD) it points
    # to the absolute path on the file system. But on Windows, it comes before the drive letter, creating an
    # unusable path, so real_path fixes that. Ugly but necessary hack.
    def real_path() #:nodoc:
      RUBY_PLATFORM =~ /win32/ && path =~ /^\/[a-zA-Z]:\// ? path[1..-1] : path
    end

  protected

    def write_internal(options, &block) #:nodoc:
      raise ArgumentError, "Either you're attempting to write a file to another host (which we don't support), or you used two slashes by mistake, where you should have file:///<path>." unless host.blank?
      temp = nil
      Tempfile.open File.basename(path) do |temp|
        temp.binmode
        with_progress_bar options[:progress] && options[:size], path.split("/"), options[:size] || 0 do |progress|
          while chunk = yield(32 * 4096)
            temp.write chunk
            progress << chunk
          end
        end
      end
      real_path.tap do |path|
        mkpath File.dirname(path)
        File.move temp.path, path
      end
    end

    @@schemes["FILE"] = FILE

  end

end