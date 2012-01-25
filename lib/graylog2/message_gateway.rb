class UnsupportedResultType < StandardError; end

# Overwrite to allow setting of document type
#  - https://github.com/karmi/tire/issues/96
module Tire::Model::Naming::ClassMethods
  def document_type(name=nil)
    @document_type = name if name
    @document_type || klass.model_name.singular
  end
end

# monkey patch, shmonkey patch (Raising Timeout from 60s to no timeout)
module Tire::HTTP::Client
  class RestClient
    def self.get(url, data=nil)
      perform ::RestClient::Request.new(:method => :get, :url => url, :payload => data, :timeout => -1).execute
    rescue ::RestClient::Exception => e
      Tire::HTTP::Response.new e.http_body, e.http_code
    end
  end
end

module Graylog2
  # XXX ELASTIC: try curb as HTTP adapter for tire. reported to be faster: https://gist.github.com/1204159
  class MessageGateway
    include Tire::Model::Search
    include Mongoid::Document

    # used if not set in config
    DEFAULT_INDEX_NAME = "graylog2"

    # [spaceship] removed Rails and Configuration dependency here
    INDEX_NAME = DEFAULT_INDEX_NAME
    TYPE_NAME = "message"

    index_name(INDEX_NAME)
    document_type(TYPE_NAME)

    @index = Tire.index(INDEX_NAME)
    @default_query_options = { :sort => "created_at desc" }

    def self.all_paginated(page = 1)
      wrap search("*", pagination_options(page).merge(@default_query_options))
    end

    def self.all_of_stream_paginated(stream_id, page = 1)
      wrap search("streams:#{stream_id}", pagination_options(page).merge(@default_query_options))
    end

    def self.all_of_host_paginated(hostname, page = 1)
      wrap search("host:#{hostname}", pagination_options(page).merge(@default_query_options))
    end

    def self.retrieve_by_id(id)
      wrap @index.retrieve(TYPE_NAME, id)
    end

    def self.dynamic_search(what, with_default_query_options = false)
      what = what.merge({:sort => { :created_at => :desc }}) if with_default_query_options
      wrap Tire.search(INDEX_NAME, what)
    end

    def self.dynamic_distribution(target, query)
      result = Array.new

      query[:facets] = {
        "distribution_result" => {
          "terms" => {
            "field" => target,
            "all_terms" => true,
            "size" => 99999
          }
        }
      }

      r = Tire.search(INDEX_NAME, query)

      # [{"term"=>"baz.example.org", "count"=>4}, {"term"=>"bar.example.com", "count"=>3}]
      r.facets["distribution_result"]["terms"].each do |r|
        next if r["count"] == 0 # ES returns the count for *every* field. Skip those that had no matches.
        result << { :distinct => r["term"], :count => r["count"] }
      end

      return result
    end

    def self.all_by_quickfilter(filters, page = 1, opts = {})
      r = search pagination_options(page).merge(@default_query_options) do
        query do
          boolean do
            # Short message
            must { string("message:#{filters[:message]}") } unless filters[:message].blank?

            # Facility
            must { term(:facility, filters[:facility]) } unless filters[:facility].blank?

            # Severity
            if !filters[:severity].blank? and filters[:severity_above].blank?
              must { term(:level, filters[:severity]) }
            end

            # Host
            must { term(:host, filters[:host]) } unless filters[:host].blank?

            # Additional fields.
            Quickfilter.extract_additional_fields_from_request(filters).each do |key, value|
              must { term("_#{key}".to_sym, value) }
            end

            # Possibly narrow down to stream?
            unless opts[:stream_id].blank?
              must { term(:streams, opts[:stream_id]) }
            end
            
            unless opts[:hostname].blank?
              must { term(:host, opts[:hostname]) }
            end
          end
        end
        
        # Severity (or higher)
        if !filters[:severity].blank? and !filters[:severity_above].blank?
          filter 'range', { :level => { :to => filters[:severity].to_i } }
        end

        # Timeframe
        if !filters[:from].blank? && !filters[:to].blank?
          range_from = Time.parse(filters[:from]).to_i
          range_to = Time.parse(filters[:to]).to_i
          
          filter 'range', { :created_at => { :gt => range_from, :lt => range_to  } }
        
        end
        
        if !filters[:date].blank?
          range = Quickfilter.get_conditions_timeframe(filters[:date])
          filter 'range', { :created_at => { :gt => range[:greater], :lt => range[:lower],  } }
        end

      end

      wrap(r)
    end

    def self.total_count
      # search with size 0 instead of count because of this issue: https://github.com/karmi/tire/issues/100
      search("*", :size => 0).total
    end

    def self.stream_count(stream_id)
      # search with size 0 instead of count because of this issue: https://github.com/karmi/tire/issues/100
      search("streams:#{stream_id}", :size => 0).total
    end

    def self.oldest_message
      wrap search("*", { :sort => "created_at asc", :size => 1 }).first
    end

    def self.all_in_range(page, from, to, opts = {})
      raise "You can only pass stream_id OR hostname" if !opts[:stream_id].blank? and !opts[:hostname].blank?

      if page.nil?
        options = pagination_options(page).merge(@default_query_options)
      else
        options = @default_query_options
      end

      r = search options do
        query do
          string("*")
        
          # Possibly narrow down to stream?
          unless opts[:stream_id].blank?
            term(:streams, opts[:stream_id])
          end
          
          # Possibly narrow down to host?
          unless opts[:hostname].blank?
            term(:host, opts[:hostname])
          end
        end
            
        filter 'range', { :created_at => { :gte => from, :lte => to } }
      end

      wrap(r)
    end

    def self.delete_message(id)
      result = Tire.index(INDEX_NAME).remove(TYPE_NAME, id)
      Tire.index(INDEX_NAME).refresh
      return false if result.nil? or result["ok"] != true

      return true
    end

    # Returns how the text is broken down to terms.
    def self.analyze(text, field = "message")
      result = Tire.index(INDEX_NAME).analyze(text, :field => "message.#{field}")
      return Array.new if result == false
      
      result["tokens"].map { |t| t["token"] }
    end

    private

    def self.wrap(x)
      return nil if x.nil?

      case(x)
        when Tire::Results::Item then Message.parse_from_elastic(x)
        when Tire::Results::Collection then wrap_collection(x)
        else
          Rails.logger.error "Unsupported result type while trying to wrap ElasticSearch response: #{x.class}"
          raise UnsupportedResultType
      end
    end

    def self.wrap_collection(c)
      r = MessageResult.new(c.results.map { |i| wrap(i) })
      r.total_result_count = c.total
      return r
    end

    def self.pagination_options(page)
      page = 1 if page.blank?

      { :per_page => Message::LIMIT, :page => page }
    end
    
  end
end
