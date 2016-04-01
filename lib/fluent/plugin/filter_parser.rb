require 'fluent/parser'
require 'thread_safe'

class Fluent::ParserFilter < Fluent::Filter
  Fluent::Plugin.register_filter('parser', self)
  @@lines_buffer = ThreadSafe::Hash.new

  config_param :key_name, :string
  config_param :reserve_data, :bool, default: false
  config_param :inject_key_prefix, :string, default: nil
  config_param :replace_invalid_sequence, :bool, default: false
  config_param :hash_value_field, :string, default: nil
  config_param :suppress_parse_error_log, :bool, default: false
  config_param :time_parse, :bool, default: true

  attr_reader :parser

  def initialize
    super
    require 'time'
  end

  def configure(conf)
    super

    @multiline_mode = conf['format'] =~ /multiline/
    @receive_handler = if @multiline_mode
                         method(:parse_multilines)
                       else
                         method(:parse_singleline)
                       end

    @parser = Fluent::TextParser.new
    @parser.estimate_current_event = false
    @parser.configure(conf)
    if !@time_parse && @parser.parser.respond_to?("time_key=".to_sym)
      # disable parse time
      @parser.parser.time_key = nil
    end

    self
  end
  def parse_singleline(tag, time, record, line, new_es, es)
    line.chomp!
    @parser.parse(line) do |t,values|
      if values
        if @time_parse
          t ||= time
        else
          t = time
        end
        r = handle_parsed(tag, record, t, values)
        new_es.add(t, r)
      else
        log.warn "pattern not match with data #{tag} '#{line}'" unless @suppress_parse_error_log
        if @reserve_data
          t = time
          r = handle_parsed(tag, record, time, {})
          es.add(t, r)
        end
      end
    end
    new_es
  end

  def parse_multilines(tag, time, record, line, new_es, es)
    if @@lines_buffer.has_key?(tag)
      matches = @parser.parser.firstline?(line)
      if matches
        index = line.index(matches[0])
        if index && index > 0
            @@lines_buffer[tag] << line[0..index]
            line = line[index..-1]
        end
        parse_singleline(tag, time, record, @@lines_buffer[tag], new_es, es)
        @@lines_buffer[tag] = line
      else
        @@lines_buffer[tag] << line
      end
    else
      @@lines_buffer[tag] = line
    end
  end

  def filter_stream(tag, es)
    new_es = Fluent::MultiEventStream.new
    es.each do |time,record|
      raw_value = record[@key_name]
      begin
        @receive_handler.call(tag, time, record, raw_value, new_es, es)
      rescue Fluent::TextParser::ParserError => e
        log.warn e.message unless @suppress_parse_error_log
      rescue ArgumentError => e
        if @replace_invalid_sequence
          unless e.message.index("invalid byte sequence in") == 0
            raise
          end
          replaced_string = replace_invalid_byte(raw_value)
          @parser.parse(replaced_string) do |t,values|
            if values
              t ||= time
              r = handle_parsed(tag, record, t, values)
              new_es.add(t, r)
            else
              log.warn "pattern not match with data '#{raw_value}'" unless @suppress_parse_error_log
              if @reserve_data
                t = time
                r = handle_parsed(tag, record, time, {})
                new_es.add(t, r)
              end
            end
          end
        else
          raise
        end
      rescue => e
        log.warn "parse failed #{e.message}" unless @suppress_parse_error_log
      end
    end
    new_es
  end

  private

  def handle_parsed(tag, record, t, values)
    if values && @inject_key_prefix
      values = Hash[values.map{|k,v| [ @inject_key_prefix + k, v ]}]
    end
    r = @hash_value_field ? {@hash_value_field => values} : values
    if @reserve_data
      r = r ? record.merge(r) : record
    end
    r
  end

  def replace_invalid_byte(string)
    replace_options = { invalid: :replace, undef: :replace, replace: '?' }
    original_encoding = string.encoding
    temporal_encoding = (original_encoding == Encoding::UTF_8 ? Encoding::UTF_16BE : Encoding::UTF_8)
    string.encode(temporal_encoding, original_encoding, replace_options).encode(original_encoding)
  end
end
