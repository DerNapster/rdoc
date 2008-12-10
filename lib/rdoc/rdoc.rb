require 'rdoc'

require 'rdoc/parser'

# Simple must come first
require 'rdoc/parser/simple'
require 'rdoc/parser/ruby'
require 'rdoc/parser/c'
require 'rdoc/parser/f95'
require 'rdoc/parser/perl'

require 'rdoc/stats'
require 'rdoc/options'

require 'rdoc/diagram'

require 'find'
require 'fileutils'
require 'time'
require 'thread'

module RDoc

  ##
  # Encapsulate the production of rdoc documentation. Basically you can use
  # this as you would invoke rdoc from the command line:
  #
  #   rdoc = RDoc::RDoc.new
  #   rdoc.document(args)
  #
  # Where +args+ is an array of strings, each corresponding to an argument
  # you'd give rdoc on the command line. See rdoc/rdoc.rb for details.

  class RDoc

    ##
    # Accessor for statistics.  Available after each call to parse_files

    attr_reader :stats

    ##
    # This is the list of supported output generators

    GENERATORS = {}

    ##
    # Add +klass+ that can generate output after parsing

    def self.add_generator(klass)
      name = klass.name.sub(/^RDoc::Generator::/, '').downcase
      GENERATORS[name] = klass
    end

    def initialize
      @stats = nil
    end

    ##
    # Report an error message and exit

    def error(msg)
      raise ::RDoc::Error, msg
    end

    ##
    # Create an output dir if it doesn't exist. If it does exist, but doesn't
    # contain the flag file <tt>created.rid</tt> then we refuse to use it, as
    # we may clobber some manually generated documentation

    def setup_output_dir(op_dir, force)
      flag_file = output_flag_file(op_dir)
      if File.exist?(op_dir)
        unless File.directory?(op_dir)
          error "'#{op_dir}' exists, and is not a directory"
        end
        begin
          created = File.read(flag_file)
        rescue SystemCallError
          error "\nDirectory #{op_dir} already exists, but it looks like it\n" +
            "isn't an RDoc directory. Because RDoc doesn't want to risk\n" +
            "destroying any of your existing files, you'll need to\n" +
            "specify a different output directory name (using the\n" +
            "--op <dir> option).\n\n"
        else
          last = (Time.parse(created) unless force rescue nil)
        end
      else
        FileUtils.mkdir_p(op_dir)
      end
      last
    end

    ##
    # Update the flag file in an output directory.

    def update_output_dir(op_dir, time)
      File.open(output_flag_file(op_dir), "w") {|f| f.puts time.rfc2822 }
    end

    ##
    # Return the path name of the flag file in an output directory.

    def output_flag_file(op_dir)
      File.join(op_dir, "created.rid")
    end

    ##
    # The .document file contains a list of file and directory name patterns,
    # representing candidates for documentation. It may also contain comments
    # (starting with '#')

    def parse_dot_doc_file(in_dir, filename, options)
      # read and strip comments
      patterns = File.read(filename).gsub(/#.*/, '')

      result = []

      patterns.split.each do |patt|
        candidates = Dir.glob(File.join(in_dir, patt))
        result.concat(normalized_file_list(options,  candidates))
      end
      result
    end

    ##
    # Given a list of files and directories, create a list of all the Ruby
    # files they contain.
    #
    # If +force_doc+ is true we always add the given files, if false, only
    # add files that we guarantee we can parse.  It is true when looking at
    # files given on the command line, false when recursing through
    # subdirectories.
    #
    # The effect of this is that if you want a file with a non-standard
    # extension parsed, you must name it explicitly.

    def normalized_file_list(options, relative_files, force_doc = false,
                             exclude_pattern = nil)
      file_list = []

      relative_files.each do |rel_file_name|
        next if exclude_pattern && exclude_pattern =~ rel_file_name
        stat = File.stat rel_file_name rescue next

        case type = stat.ftype
        when "file"
          next if @last_created and stat.mtime < @last_created

          if force_doc or ::RDoc::Parser.can_parse(rel_file_name) then
            file_list << rel_file_name.sub(/^\.\//, '')
          end
        when "directory"
          next if rel_file_name == "CVS" || rel_file_name == ".svn"
          dot_doc = File.join(rel_file_name, DOT_DOC_FILENAME)
          if File.file?(dot_doc)
            file_list.concat(parse_dot_doc_file(rel_file_name, dot_doc, options))
          else
            file_list.concat(list_files_in_directory(rel_file_name, options))
          end
        else
          raise RDoc::Error, "I can't deal with a #{type} #{rel_file_name}"
        end
      end

      file_list
    end

    ##
    # Return a list of the files to be processed in a directory. We know that
    # this directory doesn't have a .document file, so we're looking for real
    # files. However we may well contain subdirectories which must be tested
    # for .document files.

    def list_files_in_directory(dir, options)
      files = Dir.glob File.join(dir, "*")

      normalized_file_list options, files, false, options.exclude
    end

    ##
    # Parse each file on the command line, recursively entering directories.

    def parse_files(options)
      files = options.files
      files = ["."] if files.empty?

      file_list = normalized_file_list(options, files, true, options.exclude)

      return [] if file_list.empty?

      jobs = SizedQueue.new(number_of_threads * 3)
      workers = []
      file_info = []
      file_info_lock = Mutex.new

      Thread.abort_on_exception = true
      @stats = Stats.new(file_list.size, options.verbosity)
      @stats.begin_adding(number_of_threads)
      
      # Create worker threads.
      number_of_threads.times do
        thread = Thread.new do
          while (filename = jobs.pop)
            @stats.add_file(filename)
            content = read_file_contents(filename)
            top_level = ::RDoc::TopLevel.new filename

            parser = ::RDoc::Parser.for(top_level, filename, content, options,
                                        @stats)
            result = parser.scan

            file_info_lock.synchronize do
              file_info << result
            end
          end
        end
        workers << thread
      end

      # Feed filenames to the parser worker threads...
      file_list.each do |filename|
        jobs << filename
      end
      workers.size.times do
        jobs << nil
      end
      
      # ...and wait until they're done.
      workers.each do |thread|
        thread.join
      end
      
      @stats.done_adding
      
      file_info
    end

    ##
    # Format up one or more files according to the given arguments.
    #
    # For simplicity, _argv_ is an array of strings, equivalent to the strings
    # that would be passed on the command line. (This isn't a coincidence, as
    # we _do_ pass in ARGV when running interactively). For a list of options,
    # see rdoc/rdoc.rb. By default, output will be stored in a directory
    # called +doc+ below the current directory, so make sure you're somewhere
    # writable before invoking.
    #
    # Throws: RDoc::Error on error

    def document(argv)
      TopLevel::reset

      @options = Options.new
      @options.parse argv

      @last_created = nil

      unless @options.all_one_file then
        @last_created = setup_output_dir @options.op_dir, @options.force_update
      end

      start_time = Time.now

      file_info = parse_files @options

      @options.title = "RDoc Documentation"

      if file_info.empty?
        $stderr.puts "\nNo newer files." unless @options.quiet
      else
        generator = @options.generator

        $stderr.puts "\nGenerating #{generator.name.sub(/^.*::/, '')}..." unless
          @options.quiet

        @gen = generator.for @options

        pwd = Dir.pwd

        Dir.chdir @options.op_dir unless @options.all_one_file

        begin
          Diagram.new(file_info, @options).draw if @options.diagram
          @gen.generate(file_info)
          update_output_dir(".", start_time)
        ensure
          Dir.chdir(pwd)
        end
      end

      unless @options.quiet
        puts
        @stats.print
      end
    end
    
    private

    def number_of_threads
      @@number_of_threads ||=
        if RUBY_PLATFORM == "java"
          Java::java::lang::Runtime.getRuntime.availableProcessors * 2
        else
          2
        end
    end
      
    def read_file_contents(filename)
      content = if RUBY_VERSION >= '1.9' then
                  File.open(filename, "r:ascii-8bit") { |f| f.read }
                else
                  File.read filename
                end

      if defined? Encoding then
        if /coding:\s*(\S+)/ =~ content[/\A(?:.*\n){0,2}/]
          if enc = ::Encoding.find($1)
            content.force_encoding(enc)
          end
        end
      end

      content
    end
  end
end

if Gem.respond_to? :find_files then
  rdoc_extensions = Gem.find_files 'rdoc/discover'

  rdoc_extensions.each do |extension|
    begin
      load extension
    rescue => e
      warn "error loading #{extension.inspect}: #{e.message} (#{e.class})"
    end
  end
end

# require built-in generators after discovery in case they've been replaced
require 'rdoc/generator/chm'
require 'rdoc/generator/darkfish'
require 'rdoc/generator/html'
require 'rdoc/generator/ri'
require 'rdoc/generator/texinfo'
require 'rdoc/generator/xml'

