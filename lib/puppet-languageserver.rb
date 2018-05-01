begin
  original_verbose = $VERBOSE
  $VERBOSE = nil

  require 'languageserver/languageserver'
  require 'puppet-editor-services'

  %w[json_rpc_handler document_store message_router validation_queue server_capabilities puppet_parser_helper puppet_helper
     facter_helper puppet_monkey_patches providers].each do |lib|
    begin
      require "puppet-languageserver/#{lib}"
    rescue LoadError
      require File.expand_path(File.join(File.dirname(__FILE__), 'puppet-languageserver', lib))
    end
  end

  require 'puppet'
  require 'optparse'
  require 'logger'
ensure
  $VERBOSE = original_verbose
end

module PuppetLanguageServer
  def self.version
    PuppetEditorServices.version
  end

  class CommandLineParser
    def self.parse(options)
      # Set defaults here
      args = {
        stdio: false,
        port: 8081,
        ipaddress: '127.0.0.1',
        stop_on_client_exit: true,
        connection_timeout: 10,
        preload_puppet: true,
        debug: nil,
        fast_start_langserver: true,
        workspace: nil
      }

      opt_parser = OptionParser.new do |opts|
        opts.banner = 'Usage: puppet-languageserver.rb [options]'

        opts.on('-pPORT', '--port=PORT', "TCP Port to listen on.  Default is #{args[:port]}") do |port|
          args[:port] = port.to_i
        end

        opts.on('-ipADDRESS', '--ip=ADDRESS', "IP Address to listen on (0.0.0.0 for all interfaces).  Default is #{args[:ipaddress]}") do |ipaddress|
          args[:ipaddress] = ipaddress
        end

        opts.on('-c', '--no-stop', 'Do not stop the language server once a client disconnects.  Default is to stop') do |_misc|
          args[:stop_on_client_exit] = false
        end

        opts.on('-tTIMEOUT', '--timeout=TIMEOUT', "Stop the language server if a client does not connection within TIMEOUT seconds.  A value of zero will not timeout.  Default is #{args[:connection_timeout]} seconds") do |timeout|
          args[:connection_timeout] = timeout.to_i
        end

        opts.on('-d', '--no-preload', '** DEPRECATED ** Do not preload Puppet information when the language server starts.  Default is to preload') do |_misc|
          puts '** WARNING ** Using "--no-preload" may cause Puppet Type loading to be incomplete.'
          args[:preload_puppet] = false
        end

        opts.on('--debug=DEBUG', "Output debug information.  Either specify a filename or 'STDOUT'.  Default is no debug output") do |debug|
          args[:debug] = debug
        end

        opts.on('-s', '--slow-start', 'Delay starting the Language Server until Puppet initialisation has completed.  Default is to start fast') do |_misc|
          args[:fast_start_langserver] = false
        end

        opts.on('--stdio', 'Runs the server in stdio mode, without a TCP listener') do |_misc|
          args[:stdio] = true
        end

        opts.on('--enable-file-cache', 'Enables the file system cache for Puppet Objects (types, class etc.)') do |_misc|
          args[:cache] = {
            :persistent_cache => :file
          }
        end

        opts.on('--local-workspace=PATH', 'The workspace or file path that will be used to provide module-specific functionality. Default is no workspace path.') do |path|
          args[:workspace] = path
        end

        opts.on('-h', '--help', 'Prints this help') do
          puts opts
          exit
        end

        opts.on('-v', '--version', 'Prints the Langauge Server version') do
          puts PuppetLanguageServer.version
          exit
        end
      end

      opt_parser.parse!(options.dup)
      args
    end
  end

  def self.log_message(severity, message)
    PuppetEditorServices.log_message(severity, message)
  end

  def self.init_puppet(options)
    PuppetEditorServices.init_logging(options)
    log_message(:info, "Language Server is v#{PuppetEditorServices.version}")
    log_message(:info, "Using Puppet v#{Puppet.version}")

    log_message(:info, 'Initializing Puppet Helper Cache...')
    PuppetLanguageServer::PuppetHelper.configure_cache(options[:cache])

    log_message(:info, 'Initializing settings...')
    if options[:fast_start_langserver]
      Thread.new do
        init_puppet_worker(options)
      end
    else
      init_puppet_worker(options)
    end

    true
  end

  def self.init_puppet_worker(options)
    options[:puppet_settings].nil? ? Puppet.initialize_settings : Puppet.initialize_settings(options[:puppet_settings])

    # Remove all other logging destinations except for ours
    Puppet::Util::Log.destinations.clear
    Puppet::Util::Log.newdestination('null_logger')

    log_message(:info, "Using Facter v#{Facter.version}")
    if options[:preload_puppet]
      log_message(:info, 'Preloading Puppet Types (Sync)...')
      PuppetLanguageServer::PuppetHelper.load_types

      log_message(:info, 'Preloading Facter (Async)...')
      PuppetLanguageServer::FacterHelper.load_facts_async

      log_message(:info, 'Preloading Functions (Async)...')
      PuppetLanguageServer::PuppetHelper.load_functions_async

      log_message(:info, 'Preloading Classes (Async)...')
      PuppetLanguageServer::PuppetHelper.load_classes_async
    else
      log_message(:info, 'Skipping preloading Puppet')
    end
  end

  def self.rpc_server(options)
    log_message(:info, 'Starting RPC Server...')
    options[:servicename] = 'LANGUAGE SERVER'

    if options[:stdio]
      log_message(:debug, 'Using STDIO')
      server = PuppetEditorServices::SimpleSTDIOServer.new

      trap('INT') { server.stop }
      server.start(PuppetLanguageServer::JSONRPCHandler, options)
    else
      log_message(:debug, 'Using Simple TCP')
      server = PuppetEditorServices::SimpleTCPServer.new

      server.add_service(options[:ipaddress], options[:port])
      trap('INT') { server.stop_services(true) }
      server.start(PuppetLanguageServer::JSONRPCHandler, options, 2)
    end

    log_message(:info, 'Language Server exited.')
  end
end
