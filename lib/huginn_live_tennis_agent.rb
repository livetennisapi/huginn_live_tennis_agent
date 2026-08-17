# frozen_string_literal: true

require 'huginn_agent'

# Allow adding views, controllers, routes, etc. when loaded inside Huginn.
class Engine < ::Rails::Engine; end if defined?(::Rails::Engine)

HuginnAgent.register 'huginn_live_tennis_agent/live_tennis_agent'
