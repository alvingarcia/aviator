module Aviator

  class Service

    class AccessDetailsNotDefinedError < StandardError
      def initialize
        super ":access_details is not defined."
      end
    end

    class ProviderNotDefinedError < StandardError
      def initialize
        super ":provider is not defined."
      end
    end

    class ServiceNameNotDefinedError < StandardError
      def initialize
        super ":service is not defined."
      end
    end


    class UnknownRequestError < StandardError
      def initialize(request_name)
        super "Unknown request #{ request_name }."
      end
    end


    # Because we define requests in a flattened scope, we want to make sure that when each
    # request is initialized it doesn't get polluted by instance variables and methods
    # of the containing class. This builder class makes that happen by being a
    # scope gate for the file. See Metaprogramming Ruby, specifically on blocks and scope
    class RequestBuilder

      # This method gets called by the request file eval'd in self.build below
      def define_request(request_name, &block)
        klass = Class.new(Aviator::Request, &block)
        return klass, request_name
      end


      def self.build(path_to_request_file)
        clean_room = new
        clean_room.instance_eval(File.read(path_to_request_file))
      end
      
      
      private_class_method :new

    end



    attr_reader :service,
                :provider


    def initialize(opts={})
      @provider = opts[:provider] || (raise ProviderNotDefinedError.new)
      @service  = opts[:service]  || (raise ServiceNameNotDefinedError.new)

      load_requests
    end

    def request(request_name, session_data, &params)
      request_class = find_request(request_name, session_data) || (raise UnknownRequestError.new(request_name))
      request       = request_class.new(session_data, &params)

      response = http_connection.send(request.http_method) do |r|
        r.url        request.url
        r.headers.merge!(request.headers)        if request.headers?
        r.query    = request.querystring         if request.querystring?
        r.body     = JSON.generate(request.body) if request.body?
      end

      Aviator::Response.send(:new, response, request)
    end


    private


    def http_connection
      @http_connection ||= Faraday.new do |conn|
        conn.adapter Faraday.default_adapter
        conn.headers['Content-Type'] = 'application/json'
      end
    end


    # Candidate for extraction to aviator/openstack
    def find_request(name, session_data)
      version = infer_version(session_data)

      return nil unless version && requests[version]

      [:public, :admin].each do |endpoint_type|
        next unless requests[version][endpoint_type]
        pair = requests[version][endpoint_type].find{ |k, v| k == name }
        return pair[1] unless pair.nil?
      end

      nil
    end
    

    # Candidate for extraction to aviator/openstack
    def infer_version(session_data)
      if session_data.has_key? :auth_service
        session_data[:auth_service][:api_version].to_sym
      elsif session_data.has_key? :access
        service_spec = session_data[:access][:serviceCatalog].find{|s| s[:type] == service }
        service_spec[:endpoints][0][:publicURL].match(/(v\d+)\.?\d*/)[1].to_sym
      end
    end


    def load_requests
      request_file_paths = Dir.glob(Pathname.new(__FILE__).join(
                             '..',
                             '..',
                             provider.to_s,
                             service.to_s,
                             '**',
                             '*.rb'
                             ).expand_path
                           )

      @requests ||= {}

      request_file_paths.each do |path_to_file|
        klass, request_name = RequestBuilder.build(path_to_file)

        api_version   = @requests[klass.api_version] ||= {}
        endpoint_type = api_version[klass.endpoint_type] ||= {}
        endpoint_type[request_name] = klass
      end
    end


    def requests
      @requests
    end

  end

end