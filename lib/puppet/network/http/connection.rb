require 'net/https'
require 'puppet/ssl/host'
require 'puppet/ssl/configuration'
require 'puppet/ssl/validator'
require 'puppet/network/authentication'
require 'puppet/network/http'
require 'uri'

module Puppet::Network::HTTP

  # This will be raised if too many redirects happen for a given HTTP request
  class RedirectionLimitExceededException < Puppet::Error ; end
  class RetryLimitExceededException < Puppet::Error ; end

  # This class provides simple methods for issuing various types of HTTP
  # requests.  It's interface is intended to mirror Ruby's Net::HTTP
  # object, but it provides a few important bits of additional
  # functionality.  Notably:
  #
  # * Any HTTPS requests made using this class will use Puppet's SSL
  #   certificate configuration for their authentication, and
  # * Provides some useful error handling for any SSL errors that occur
  #   during a request.
  # @api public
  class Connection
    include Puppet::Network::Authentication

    OPTION_DEFAULTS = {
      :use_ssl => true,
      :verify => nil,
      :redirect_limit => 10,
      :retry_limit => 2,
    }

    # Creates a new HTTP client connection to `host`:`port`.
    # @param host [String] the host to which this client will connect to
    # @param port [Fixnum] the port to which this client will connect to
    # @param options [Hash] options influencing the properties of the created
    #   connection,
    # @option options [Boolean] :use_ssl true to connect with SSL, false
    #   otherwise, defaults to true
    # @option options [#setup_connection] :verify An object that will configure
    #   any verification to do on the connection
    # @option options [Fixnum] :redirect_limit the number of allowed
    #   redirections, defaults to 10 passing any other option in the options
    #   hash results in a Puppet::Error exception
    #
    # @note the HTTP connection itself happens lazily only when {#request}, or
    #   one of the {#get}, {#post}, {#delete}, {#head} or {#put} is called
    # @note The correct way to obtain a connection is to use one of the factory
    #   methods on {Puppet::Network::HttpPool}
    # @api private
    def initialize(host, port, options = {})
      @host = host
      @port = port

      unknown_options = options.keys - OPTION_DEFAULTS.keys
      raise Puppet::Error, "Unrecognized option(s): #{unknown_options.map(&:inspect).sort.join(', ')}" unless unknown_options.empty?

      options = OPTION_DEFAULTS.merge(options)
      @use_ssl = options[:use_ssl]
      @verify = options[:verify]
      @redirect_limit = options[:redirect_limit]
      @site = Puppet::Network::HTTP::Site.new(@use_ssl ? 'https' : 'http', host, port)
      @pool = Puppet.lookup(:http_pool)
      @retry_limit = options[:retry_limit]
    end

    # @!macro [new] common_options
    #   @param options [Hash] options influencing the request made
    #   @option options [Hash{Symbol => String}] :basic_auth The basic auth
    #     :username and :password to use for the request
    #     :idempotent Whether the request is idempotent (can be retried)

    # @param path [String]
    # @param headers [Hash{String => String}]
    # @!macro common_options
    # @api public
    def get(path, headers = {}, options = {}, &block)
      opts = { :idempotent => true }.merge(options)
      request_with_redirects(Net::HTTP::Get.new(path, headers), opts, &block)
    end

    # @param path [String]
    # @param data [String]
    # @param headers [Hash{String => String}]
    # @!macro common_options
    # @api public
    def post(path, data, headers = nil, options = {}, &block)
      request = Net::HTTP::Post.new(path, headers)
      request.body = data
      request_with_redirects(request, options, &block)
    end

    # @param path [String]
    # @param headers [Hash{String => String}]
    # @!macro common_options
    # @api public
    def head(path, headers = {}, options = {}, &block)
      opts = { :idempotent => true }.merge(options)
      request_with_redirects(Net::HTTP::Head.new(path, headers), opts, &block)
    end

    # @param path [String]
    # @param headers [Hash{String => String}]
    # @!macro common_options
    # @api public
    def delete(path, headers = {'Depth' => 'Infinity'}, options = {})
      request_with_redirects(Net::HTTP::Delete.new(path, headers), options)
    end

    # @param path [String]
    # @param data [String]
    # @param headers [Hash{String => String}]
    # @!macro common_options
    # @api public
    def put(path, data, headers = nil, options = {})
      request = Net::HTTP::Put.new(path, headers)
      request.body = data
      request_with_redirects(request, options)
    end

    def request(method, *args)
      self.send(method, *args)
    end

    def request_get(*args, &block)
      self.send(:get, *args, &block)
    end

    def request_head(*args, &block)
      self.send(:head, *args, &block)
    end

    def request_post(*args, &block)
      self.send(:post, *args, &block)
    end

    # The address to connect to.
    def address
      @site.host
    end

    # The port to connect to.
    def port
      @site.port
    end

    # Whether to use ssl
    def use_ssl?
      @site.use_ssl?
    end

    private

    def request_with_redirects(request, options, &block)
      current_request = request
      current_site = @site
      response = nil
      redirects = 0

      0.upto(@redirect_limit) do |redirection|
        return response if response

        with_connection(current_site) do |connection|
          apply_options_to(current_request, options) if redirects.zero?

          if options[:idempotent]
            current_response = request_with_retries(connection, current_request, &block)
          else
            current_response = execute_request(connection, current_request, &block)
          end

          if [301, 302, 307].include?(current_response.code.to_i)

            # handle the redirection
            location = URI.parse(current_response['location'])
            current_site = current_site.move_to(location)

            # update to the current request path
            current_request = current_request.class.new(location.path)
            current_request.body = request.body
            request.each do |header, value|
              unless Puppet[:location_trusted]
                # skip adding potentially sensitive header to other hosts
                next if header.casecmp('Authorization').zero? && request.uri.host.casecmp(location.host) != 0
                next if header.casecmp('Cookie').zero? && request.uri.host.casecmp(location.host) != 0
              end
              current_request[header] = value
            end
          else
            response = current_response
          end
          redirects += 1
        end

        # and try again...
      end

      raise RedirectionLimitExceededException, "Too many HTTP redirections for #{@host}:#{@port}"
    end

    def request_with_retries(connection, request, &block)
      e = nil
      response = nil
      (@retry_limit + 1).times do |i|
        e = nil
        response = nil
        begin
          response = execute_request(connection, request, &block)
          break if ![500, 502, 503, 504].include?(response.code.to_i)
        rescue SystemCallError, Net::HTTPBadResponse, Timeout::Error, SocketError => e
        end
        sleep 3 unless i == (@retry_limit)
        # and try again...
      end
      # We reached the max retries.  We should either return the last response
      # or raise an exception if we have one from the latest attempt.
      return response if response
      raise RetryLimitExceededException, "Too many HTTP retries for #{@host}:#{@port}" if e
    end

    def apply_options_to(request, options)
      if options[:basic_auth]
        request.basic_auth(options[:basic_auth][:user], options[:basic_auth][:password])
      end
    end

    def execute_request(connection, request, &block)
      response = connection.request(request, &block)

      # Check the peer certs and warn if they're nearing expiration.
      warn_if_near_expiration(*@verify.peer_certs)

      response
    end

    def with_connection(site, &block)
      response = nil
      @pool.with_connection(site, @verify) do |conn|
        response = yield conn
      end
      response
    rescue OpenSSL::SSL::SSLError => error
      if error.message.include? "certificate verify failed"
        msg = error.message
        msg << ": [" + @verify.verify_errors.join('; ') + "]"
        raise Puppet::Error, msg, error.backtrace
      elsif error.message =~ /hostname.*not match.*server certificate/
        leaf_ssl_cert = @verify.peer_certs.last

        valid_certnames = [leaf_ssl_cert.name, *leaf_ssl_cert.subject_alt_names].uniq
        msg = valid_certnames.length > 1 ? "one of #{valid_certnames.join(', ')}" : valid_certnames.first
        msg = "Server hostname '#{site.host}' did not match server certificate; expected #{msg}"

        raise Puppet::Error, msg, error.backtrace
      else
        raise
      end
    end
  end
end
