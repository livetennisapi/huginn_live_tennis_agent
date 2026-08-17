# frozen_string_literal: true

# A lightweight stand-in for Huginn's Agent base class, so the gem's specs run
# standalone (`bundle exec rspec`) without cloning the full Huginn Rails app.
# It mirrors the slice of the Agent API this gem uses: options / interpolated
# (with `{% credential ... %}` resolution), memory, create_event, log/error,
# validation errors, boolify, and recent_error_logs?.
#
# The full huginn_agent integration harness (see the Rakefile note) remains the
# reference environment; this shim exists to keep the unit specs fast and
# dependency-free.

require 'json'

# The minimal slice of ActiveSupport the agent relies on (present in any real
# Huginn install; defined here so the standalone specs need no Rails gems).
class Object
  def blank?
    respond_to?(:empty?) ? !!empty? : !self
  end unless method_defined?(:blank?)

  def present?
    !blank?
  end unless method_defined?(:present?)

  def presence
    self if present?
  end unless method_defined?(:presence)
end

class String
  def blank?
    strip.empty?
  end
end

class NilClass
  def blank?
    true
  end
end

class Agent
  TYPES = []

  class << self
    def default_schedule(schedule = nil)
      @default_schedule = schedule if schedule
      @default_schedule
    end

    def description(md = nil)
      @description = md if md
      @description
    end

    def event_description(md = nil)
      @event_description = md if md
      @event_description
    end

    def cannot_receive_events!
      @cannot_receive_events = true
    end

    def can_dry_run!
      @can_dry_run = true
    end
  end

  class Errors
    def initialize
      @messages = Hash.new { |hash, key| hash[key] = [] }
    end

    def add(key, message)
      @messages[key] << message
    end

    def [](key)
      @messages[key]
    end

    def full_messages
      @messages.values.flatten
    end

    def empty?
      @messages.values.all?(&:empty?)
    end
  end

  FakeEvent = Struct.new(:payload)

  attr_accessor :name, :user, :memory
  attr_reader :events, :logs, :error_logs

  def initialize(name: 'agent', options: {})
    @name = name
    # Huginn stores options JSON-serialized (string keys); mirror that.
    @options = JSON.parse(options.to_json)
    @memory = {}
    @events = []
    @logs = []
    @error_logs = []
    @credentials = {}
  end

  def options
    @options
  end

  def options=(options)
    @options = JSON.parse(options.to_json)
  end

  # Minimal Liquid stand-in: resolves `{% credential name %}` tags in string
  # option values, which is the only interpolation this gem's specs exercise.
  def interpolated
    @options.each_with_object({}) do |(key, value), result|
      result[key] = value.is_a?(String) ? interpolate_string(value) : value
    end
  end

  def set_credential(name, value)
    @credentials[name.to_s] = value
  end

  def credential(name)
    @credentials[name.to_s]
  end

  def create_event(payload:)
    @events << FakeEvent.new(JSON.parse(payload.to_json))
  end

  def log(message)
    @logs << message
  end

  def error(message)
    @error_logs << message
    @logs << message
  end

  def recent_error_logs?
    @error_logs.any?
  end

  def errors
    @errors ||= Errors.new
  end

  def valid?
    @errors = Errors.new
    validate_options if respond_to?(:validate_options)
    errors.empty?
  end

  def save!
    raise "Validation failed: #{errors.full_messages.join(', ')}" unless valid?

    true
  end

  def boolify(value)
    case value
    when true, 'true' then true
    when false, 'false' then false
    end
  end

  private

  def interpolate_string(string)
    string.gsub(/\{%\s*credential\s+(\S+)\s*%\}/) { credential(Regexp.last_match(1)).to_s }
  end
end
