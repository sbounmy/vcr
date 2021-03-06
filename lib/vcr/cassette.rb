require 'fileutils'
require 'erb'

require 'vcr/cassette/http_interaction_list'
require 'vcr/cassette/reader'
require 'vcr/cassette/serializers'

module VCR
  class Cassette
    VALID_RECORD_MODES = [:all, :none, :new_episodes, :once]

    attr_reader :name, :record_mode, :match_requests_on, :erb, :re_record_interval, :tag

    def initialize(name, options = {})
      options = VCR.configuration.default_cassette_options.merge(options)
      invalid_options = options.keys - [
        :record, :erb, :match_requests_on, :re_record_interval, :tag,
        :update_content_length_header, :allow_playback_repeats, :exclusive,
        :serialize_with
      ]

      if invalid_options.size > 0
        raise ArgumentError.new("You passed the following invalid options to VCR::Cassette.new: #{invalid_options.inspect}.")
      end

      @name                         = name
      @record_mode                  = options[:record]
      @erb                          = options[:erb]
      @match_requests_on            = options[:match_requests_on]
      @re_record_interval           = options[:re_record_interval]
      @tag                          = options[:tag]
      @update_content_length_header = options[:update_content_length_header]
      @allow_playback_repeats       = options[:allow_playback_repeats]
      @exclusive                    = options[:exclusive]
      @serializer                   = VCR.cassette_serializers[options[:serialize_with]]
      @record_mode                  = :all if should_re_record?
      @parent_list                  = @exclusive ? HTTPInteractionList::NullList : VCR.http_interactions

      raise_error_unless_valid_record_mode
    end

    def eject
      write_recorded_interactions_to_disk
    end

    def previously_recorded_interactions
      @previously_recorded_interactions ||= if file && File.size?(file)
        deserialized_hash['http_interactions'].map { |h| HTTPInteraction.from_hash(h) }.tap do |interactions|
          invoke_hook(:before_playback, interactions)

          interactions.reject! do |i|
            i.request.uri.is_a?(String) && VCR.request_ignorer.ignore?(i.request)
          end

          if update_content_length_header?
            interactions.each { |i| i.response.update_content_length_header }
          end
        end
      else
        []
      end
    end

    def http_interactions
      @http_interactions ||= HTTPInteractionList.new \
        should_stub_requests? ? previously_recorded_interactions : [],
        match_requests_on,
        @allow_playback_repeats,
        @parent_list
    end

    def record_http_interaction(interaction)
      new_recorded_interactions << interaction
    end

    def new_recorded_interactions
      @new_recorded_interactions ||= []
    end

    def file
      return nil unless VCR.configuration.cassette_library_dir
      File.join(VCR.configuration.cassette_library_dir, "#{sanitized_name}.#{@serializer.file_extension}")
    end

    def update_content_length_header?
      @update_content_length_header
    end

    def recording?
      case record_mode
        when :none; false
        when :once; file.nil? || !File.size?(file)
        else true
      end
    end

    def serializable_hash
      {
        "http_interactions" => interactions_to_record.map(&:to_hash),
        "recorded_with"     => "VCR #{VCR.version}"
      }
    end

  private

    def sanitized_name
      name.to_s.gsub(/[^\w\-\/]+/, '_')
    end

    def raise_error_unless_valid_record_mode
      unless VALID_RECORD_MODES.include?(record_mode)
        raise ArgumentError.new("#{record_mode} is not a valid cassette record mode.  Valid modes are: #{VALID_RECORD_MODES.inspect}")
      end
    end

    def should_re_record?
      return false unless @re_record_interval
      return false unless earliest_interaction_recorded_at
      return false unless File.exist?(file)
      return false unless InternetConnection.available?

      earliest_interaction_recorded_at + @re_record_interval < Time.now
    end

    def earliest_interaction_recorded_at
      previously_recorded_interactions.map(&:recorded_at).min
    end

    def should_stub_requests?
      record_mode != :all
    end

    def should_remove_matching_existing_interactions?
      record_mode == :all
    end

    def raw_yaml_content
      VCR::Cassette::Reader.new(file, erb).read
    end

    def merged_interactions
      old_interactions = previously_recorded_interactions

      if should_remove_matching_existing_interactions?
        new_interaction_list = HTTPInteractionList.new(new_recorded_interactions, match_requests_on)
        old_interactions = old_interactions.reject do |i|
          new_interaction_list.has_interaction_matching?(i.request)
        end
      end

      old_interactions + new_recorded_interactions
    end

    def interactions_to_record
      merged_interactions.tap do |interactions|
        invoke_hook(:before_record, interactions)
      end
    end

    def write_recorded_interactions_to_disk
      return unless VCR.configuration.cassette_library_dir
      return if new_recorded_interactions.none?
      hash = serializable_hash
      return if hash["http_interactions"].none?

      directory = File.dirname(file)
      FileUtils.mkdir_p directory unless File.exist?(directory)
      File.open(file, 'w') { |f| f.write @serializer.serialize(hash) }
    end

    def invoke_hook(type, interactions)
      interactions.delete_if do |i|
        VCR.configuration.invoke_hook(type, tag, i, self)
        i.ignored?
      end
    end

    def deserialized_hash
      @deserialized_hash ||= @serializer.deserialize(raw_yaml_content).tap do |hash|
        unless hash.is_a?(Hash) && hash['http_interactions'].is_a?(Array)
          raise Errors::InvalidCassetteFormatError.new \
            "#{file} does not appear to be a valid VCR 2.0 cassette. " +
            "VCR 1.x cassettes are not valid with VCR 2.0. When upgrading from " +
            "VCR 1.x, it is recommended that you delete all your existing cassettes and " +
            "re-record them, or use the provided vcr:migrate_cassettes rake task to migrate " +
            "them. For more info, see the VCR upgrade guide."
        end
      end
    end
  end
end
