# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module Agents
  class LiveTennisAgent < Agent
    cannot_receive_events!
    can_dry_run!

    default_schedule 'every_30m'

    API_BASE = 'https://api.livetennisapi.com/api/public/v1'
    MODES = %w[live_scores fixtures].freeze
    TOURS = %w[atp wta challenger itf juniors].freeze

    description <<-MD
      The Live Tennis Agent polls the [Live Tennis API](https://livetennisapi.com)
      (we run the Live Tennis API — this is a vendor-authored agent) and emits
      events when match state changes: `match_started`, `score_changed` and
      `match_finished` in `live_scores` mode, or `new_fixture` / `fixture_updated`
      in `fixtures` mode.

      You need an API key. The FREE keyed tier (no card) is at
      https://livetennisapi.com/subscribe/free and includes live scores
      (score / server / break-point state), players, fixtures and usage,
      at 30 requests/minute and 100 requests/day.

      **Polling honesty:** 100 requests/day means a FREE key supports roughly
      15-minute-or-slower cadence checks, not continuous fast polling. The
      default schedule here is `every_30m` (≈48 checks/day), which leaves room
      for the finished-match lookups this agent makes. Faster schedules need a
      paid tier.

      Options:

      * `api_key` — your Live Tennis API key. Reference a
        [credential](https://github.com/huginn/huginn/wiki/Liquid-Templating#credentials)
        rather than pasting the key: `{% credential live_tennis_api_key %}`.
      * `mode` — `live_scores` (default) or `fixtures`.
      * `tour` — optional filter: `atp`, `wta`, `challenger`, `itf` or `juniors`.
        Leave blank for all tours.
      * `lookup_finished` — `live_scores` mode only (default `true`): when a
        tracked match leaves the live board, fetch `GET /matches/{id}` once
        (a FREE endpoint) to confirm the final state and include the winner in
        the `match_finished` event. Set to `false` to save one request per
        finished match; the event then carries only the last-known score.

      The very first check primes the agent's memory without emitting events,
      so enabling the agent mid-tournament does not flood your scenario with
      stale `match_started` events. State transitions are emitted from the
      second check onward.

      `break_point` on `score_changed` events is derived from the score:
      receiver at `AD`, or receiver at `40` while the server is at `0`/`15`/`30`;
      it is never set during tiebreaks and is `null` whenever the server or
      point state is unknown.
    MD

    event_description <<-MD
      In `live_scores` mode:

          {
            "event_type": "match_started",
            "match": { "id": 12345, "tournament": "...", "tour": "atp", "players": {...}, "score": {...}, ... }
          }

          {
            "event_type": "score_changed",
            "match_id": 12345,
            "tournament": "...",
            "tour": "atp",
            "players": { "p1": "...", "p2": "..." },
            "score": { "sets": [...], "games": [...], "points": [...], "server": 1, "is_tiebreak": false, ... },
            "previous_score": { ... },
            "break_point": true
          }

          {
            "event_type": "match_finished",
            "match_id": 12345,
            "tournament": "...",
            "tour": "atp",
            "players": { "p1": "...", "p2": "..." },
            "last_known_score": { ... },
            "confirmed": true,
            "status": "completed",
            "winner": 1,
            "event_status": null,
            "final_score": { ... }
          }

      (`confirmed`, `status`, `winner`, `event_status` and `final_score` are
      present only when `lookup_finished` confirmed the final state; with
      `lookup_finished: false` — or when the confirming request fails — the
      event carries `"confirmed": false` and the last-known fields only.)

      In `fixtures` mode:

          {
            "event_type": "new_fixture",
            "fixture": { "id": 678, "start_time": "2026-08-18T10:00:00Z", "player1_name": "...", "player2_name": "...", ... }
          }

          {
            "event_type": "fixture_updated",
            "fixture": { ... },
            "previous_start_time": null
          }
    MD

    def default_options
      {
        'api_key' => '{% credential live_tennis_api_key %}',
        'mode' => 'live_scores',
        'tour' => '',
        'lookup_finished' => 'true'
      }
    end

    def validate_options
      errors.add(:base, 'api_key is required') unless options['api_key'].present?

      unless MODES.include?(options['mode'])
        errors.add(:base, "mode must be one of: #{MODES.join(', ')}")
      end

      if options['tour'].present? && !TOURS.include?(options['tour'])
        errors.add(:base, "tour must be one of: #{TOURS.join(', ')} (or blank for all tours)")
      end

      if options['lookup_finished'].present? && boolify(options['lookup_finished']).nil?
        errors.add(:base, 'lookup_finished must be true or false')
      end
    end

    def working?
      !recent_error_logs?
    end

    def check
      if interpolated['mode'] == 'fixtures'
        check_fixtures
      else
        check_live_scores
      end
    end

    private

    def check_live_scores
      body = api_get('/matches', 'status' => 'live', 'tour' => tour_param)
      return unless body

      matches = body['data'] || []
      known = memory['matches'] || {}
      primed = memory['primed_live']
      current = {}

      matches.each do |match|
        id = match['id'].to_s
        snap = snapshot(match)
        current[id] = snap

        if !known.key?(id)
          emit_match_started(match) if primed
        elsif known[id]['score_sig'] != snap['score_sig']
          emit_score_changed(match, known[id])
        end
      end

      if primed
        (known.keys - current.keys).each do |id|
          handle_departed_match(id, known[id], current)
        end
      end

      memory['matches'] = current
      memory['primed_live'] = true
    end

    def check_fixtures
      body = api_get('/fixtures', 'tour' => tour_param)
      return unless body

      fixtures = body['data'] || []
      known = memory['fixtures'] || {}
      primed = memory['primed_fixtures']

      fixtures.each do |fixture|
        id = fixture['id'].to_s

        if !known.key?(id)
          if primed
            create_event payload: { 'event_type' => 'new_fixture', 'fixture' => fixture }
          end
        elsif known[id] != fixture['start_time']
          create_event payload: {
            'event_type' => 'fixture_updated',
            'fixture' => fixture,
            'previous_start_time' => known[id]
          }
        end

        known[id] = fixture['start_time']
      end

      # Keep memory bounded: if the map grows past 1000 fixtures, keep only the
      # ids present in the latest response.
      if known.size > 1000
        current_ids = fixtures.map { |f| f['id'].to_s }
        known = known.select { |id, _| current_ids.include?(id) }
      end

      memory['fixtures'] = known
      memory['primed_fixtures'] = true
    end

    def emit_match_started(match)
      create_event payload: {
        'event_type' => 'match_started',
        'match' => match
      }
    end

    def emit_score_changed(match, previous)
      create_event payload: {
        'event_type' => 'score_changed',
        'match_id' => match['id'],
        'tournament' => match['tournament'],
        'tour' => match['tour'],
        'players' => {
          'p1' => match.dig('players', 'p1', 'name'),
          'p2' => match.dig('players', 'p2', 'name')
        },
        'score' => match['score'],
        'previous_score' => previous['score'],
        'break_point' => break_point?(match['score'])
      }
    end

    # A tracked match is no longer on the live board. Optionally confirm its
    # final state with one FREE `GET /matches/{id}` request. If the match turns
    # out to still be live (a transient gap in the list), keep tracking it and
    # emit nothing; if it went back to `upcoming` (e.g. postponed), drop it
    # silently — it will emit `match_started` when it actually starts.
    def handle_departed_match(id, previous, current)
      final = lookup_finished? ? api_get("/matches/#{id}") : nil

      if final
        case final['status']
        when 'live'
          current[id] = snapshot(final)
          return
        when 'upcoming'
          return
        end
      end

      payload = {
        'event_type' => 'match_finished',
        'match_id' => id.to_i,
        'tournament' => previous['tournament'],
        'tour' => previous['tour'],
        'players' => { 'p1' => previous['p1'], 'p2' => previous['p2'] },
        'last_known_score' => previous['score'],
        'confirmed' => !final.nil?
      }

      if final
        payload['status'] = final['status']
        payload['winner'] = final['winner']
        payload['event_status'] = final['event_status']
        payload['final_score'] = final['score']
      end

      create_event payload: payload
    end

    def snapshot(match)
      {
        'tournament' => match['tournament'],
        'tour' => match['tour'],
        'p1' => match.dig('players', 'p1', 'name'),
        'p2' => match.dig('players', 'p2', 'name'),
        'score' => match['score'],
        'score_sig' => score_sig(match['score'])
      }
    end

    # Fingerprint of the parts of a score that constitute a state change.
    # Deliberately ignores `timestamp` (changes on every commit) and the
    # ULTRA-only model fields.
    def score_sig(score)
      return '' if score.nil?

      [
        score['sets'], score['games'], score['points'],
        score['server'], score['is_tiebreak']
      ].to_json
    end

    # Break-point derivation: receiver at AD, or receiver at 40 while the
    # server is at 0/15/30. Never in tiebreaks. nil (unknown) when the server
    # or point state is null.
    def break_point?(score)
      return nil if score.nil?
      return false if score['is_tiebreak']

      server = score['server']
      points = score['points']
      return nil if server.nil? || !points.is_a?(Array) || points.length < 2

      receiver = server == 1 ? 2 : 1
      server_points = points[server - 1]
      receiver_points = points[receiver - 1]
      return nil if server_points.nil? || receiver_points.nil?

      receiver_points == 'AD' ||
        (receiver_points == '40' && %w[0 15 30].include?(server_points))
    end

    def lookup_finished?
      raw = interpolated['lookup_finished']
      return true unless raw.present?

      boolify(raw) != false
    end

    def tour_param
      interpolated['tour'].presence
    end

    def api_get(path, params = {})
      uri = URI(API_BASE + path)
      query = params.reject { |_, v| v.nil? || v == '' }
      uri.query = URI.encode_www_form(query) unless query.empty?

      request = Net::HTTP::Get.new(uri)
      request['X-API-Key'] = interpolated['api_key']
      request['User-Agent'] = 'Huginn - huginn_live_tennis_agent'

      response = Net::HTTP.start(uri.hostname, uri.port,
                                 use_ssl: uri.scheme == 'https',
                                 open_timeout: 10, read_timeout: 20) do |http|
        http.request(request)
      end

      unless response.is_a?(Net::HTTPSuccess)
        error("Live Tennis API request to #{path} failed: HTTP #{response.code} #{response.body.to_s[0, 200]}")
        return nil
      end

      JSON.parse(response.body)
    rescue JSON::ParserError => e
      error("Live Tennis API returned unparseable JSON from #{path}: #{e.message}")
      nil
    rescue SocketError, Timeout::Error, Errno::ECONNREFUSED, Errno::ECONNRESET,
           Errno::EHOSTUNREACH, OpenSSL::SSL::SSLError => e
      error("Live Tennis API request to #{path} failed: #{e.class}: #{e.message}")
      nil
    end
  end
end
