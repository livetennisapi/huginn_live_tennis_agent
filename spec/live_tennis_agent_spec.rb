# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Agents::LiveTennisAgent do
  let(:api_base) { Agents::LiveTennisAgent::API_BASE }

  def match_fixture(id:, p1: 'Player One', p2: 'Player Two', status: 'live',
                    sets: [0, 0], games: [[2], [1]], points: %w[15 30],
                    server: 1, is_tiebreak: false, winner: nil, event_status: nil)
    {
      'id' => id,
      'tournament' => 'Cincinnati Open',
      'tour' => 'atp',
      'surface' => 'hard',
      'status' => status,
      'is_doubles' => false,
      'players' => {
        'p1' => { 'id' => id * 10 + 1, 'name' => p1 },
        'p2' => { 'id' => id * 10 + 2, 'name' => p2 }
      },
      'score' => {
        'sets' => sets,
        'games' => games,
        'points' => points,
        'server' => server,
        'is_tiebreak' => is_tiebreak,
        'timestamp' => '2026-08-17T12:00:00Z'
      },
      'winner' => winner,
      'event_status' => event_status
    }
  end

  def fixture_fixture(id:, start_time: '2026-08-18T10:00:00Z')
    {
      'id' => id,
      'event_date' => '2026-08-18',
      'start_time' => start_time,
      'tournament' => 'Cincinnati Open',
      'tour' => 'atp',
      'round' => 'R16',
      'player1_name' => 'Player One',
      'player2_name' => 'Player Two'
    }
  end

  def stub_live_matches(matches)
    stub_request(:get, "#{api_base}/matches?status=live")
      .to_return(status: 200,
                 body: { 'data' => matches, 'meta' => { 'total' => matches.size } }.to_json,
                 headers: { 'Content-Type' => 'application/json' })
  end

  def stub_fixtures(fixtures)
    stub_request(:get, "#{api_base}/fixtures")
      .to_return(status: 200,
                 body: { 'data' => fixtures, 'meta' => { 'total' => fixtures.size } }.to_json,
                 headers: { 'Content-Type' => 'application/json' })
  end

  before do
    @valid_options = {
      'api_key' => '{% credential live_tennis_api_key %}',
      'mode' => 'live_scores',
      'tour' => '',
      'lookup_finished' => 'true'
    }
    @checker = described_class.new(name: 'LiveTennisAgent', options: @valid_options)
    @checker.set_credential('live_tennis_api_key', 'test-key-123')
    @checker.save!
  end

  describe 'validation' do
    it 'is valid with the default options' do
      expect(@checker).to be_valid
    end

    it 'requires api_key' do
      @checker.options = @valid_options.merge('api_key' => '')
      expect(@checker).not_to be_valid
      expect(@checker.errors[:base]).to include('api_key is required')
    end

    it 'rejects an unknown mode' do
      @checker.options = @valid_options.merge('mode' => 'doubles_only')
      expect(@checker).not_to be_valid
    end

    it 'accepts both documented modes' do
      %w[live_scores fixtures].each do |mode|
        @checker.options = @valid_options.merge('mode' => mode)
        expect(@checker).to be_valid
      end
    end

    it 'rejects an unknown tour' do
      @checker.options = @valid_options.merge('tour' => 'moon')
      expect(@checker).not_to be_valid
    end

    it 'accepts every documented tour filter' do
      %w[atp wta challenger itf juniors].each do |tour|
        @checker.options = @valid_options.merge('tour' => tour)
        expect(@checker).to be_valid
      end
    end

    it 'rejects a non-boolean lookup_finished' do
      @checker.options = @valid_options.merge('lookup_finished' => 'maybe')
      expect(@checker).not_to be_valid
    end
  end

  describe '#working?' do
    it 'is true when there are no recent error logs' do
      expect(@checker.working?).to be true
    end

    it 'is false after an error has been logged' do
      @checker.error('boom')
      expect(@checker.working?).to be false
    end
  end

  describe '#check in live_scores mode' do
    it 'sends the API key from the referenced credential in X-API-Key' do
      stub = stub_live_matches([])
      @checker.check
      expect(stub.with(headers: { 'X-API-Key' => 'test-key-123' })).to have_been_requested
    end

    it 'passes the tour filter through to the API when set' do
      @checker.options = @valid_options.merge('tour' => 'wta')
      stub = stub_request(:get, "#{api_base}/matches?status=live&tour=wta")
             .to_return(status: 200, body: { 'data' => [] }.to_json)
      @checker.check
      expect(stub).to have_been_requested
    end

    it 'primes memory on the first check without emitting events' do
      stub_live_matches([match_fixture(id: 1), match_fixture(id: 2)])
      expect { @checker.check }.not_to change { @checker.events.count }
      expect(@checker.memory['matches'].keys).to match_array(%w[1 2])
      expect(@checker.memory['primed_live']).to be true
    end

    context 'once primed' do
      before do
        stub_live_matches([match_fixture(id: 1)])
        @checker.check # priming run
      end

      it 'emits match_started when a new match appears on the live board' do
        stub_live_matches([match_fixture(id: 1), match_fixture(id: 7, p1: 'New Player')])
        expect { @checker.check }.to change { @checker.events.count }.by(1)

        payload = @checker.events.last.payload
        expect(payload['event_type']).to eq 'match_started'
        expect(payload['match']['id']).to eq 7
        expect(payload['match']['players']['p1']['name']).to eq 'New Player'
      end

      it 'emits score_changed with old and new score when the score moves' do
        stub_live_matches([match_fixture(id: 1, points: %w[30 40])])
        expect { @checker.check }.to change { @checker.events.count }.by(1)

        payload = @checker.events.last.payload
        expect(payload['event_type']).to eq 'score_changed'
        expect(payload['match_id']).to eq 1
        expect(payload['score']['points']).to eq %w[30 40]
        expect(payload['previous_score']['points']).to eq %w[15 30]
        expect(payload['players']).to eq('p1' => 'Player One', 'p2' => 'Player Two')
      end

      it 'emits no events when nothing changed' do
        stub_live_matches([match_fixture(id: 1)])
        expect { @checker.check }.not_to change { @checker.events.count }
      end

      it 'ignores timestamp-only changes in the score' do
        unchanged = match_fixture(id: 1)
        unchanged['score']['timestamp'] = '2026-08-17T12:05:00Z'
        stub_live_matches([unchanged])
        expect { @checker.check }.not_to change { @checker.events.count }
      end

      it 'emits match_finished with the confirmed winner when a match leaves the board' do
        stub_live_matches([])
        stub_request(:get, "#{api_base}/matches/1")
          .to_return(status: 200,
                     body: match_fixture(id: 1, status: 'completed', winner: 2).to_json)

        expect { @checker.check }.to change { @checker.events.count }.by(1)

        payload = @checker.events.last.payload
        expect(payload['event_type']).to eq 'match_finished'
        expect(payload['match_id']).to eq 1
        expect(payload['confirmed']).to be true
        expect(payload['status']).to eq 'completed'
        expect(payload['winner']).to eq 2
        expect(payload['last_known_score']['points']).to eq %w[15 30]
        expect(@checker.memory['matches']).not_to have_key('1')
      end

      it 'keeps tracking (and stays silent) when the lookup says the match is still live' do
        stub_live_matches([])
        stub_request(:get, "#{api_base}/matches/1")
          .to_return(status: 200, body: match_fixture(id: 1, status: 'live').to_json)

        expect { @checker.check }.not_to change { @checker.events.count }
        expect(@checker.memory['matches']).to have_key('1')
      end

      it 'drops a match silently when the lookup says it went back to upcoming' do
        stub_live_matches([])
        stub_request(:get, "#{api_base}/matches/1")
          .to_return(status: 200, body: match_fixture(id: 1, status: 'upcoming').to_json)

        expect { @checker.check }.not_to change { @checker.events.count }
        expect(@checker.memory['matches']).not_to have_key('1')
      end

      it 'emits an unconfirmed match_finished without an extra request when lookup_finished is false' do
        @checker.options = @valid_options.merge('lookup_finished' => 'false')
        stub_live_matches([])

        expect { @checker.check }.to change { @checker.events.count }.by(1)

        payload = @checker.events.last.payload
        expect(payload['event_type']).to eq 'match_finished'
        expect(payload['confirmed']).to be false
        expect(payload).not_to have_key('winner')
        expect(a_request(:get, "#{api_base}/matches/1")).not_to have_been_made
      end

      it 'emits an unconfirmed match_finished when the confirming lookup fails' do
        stub_live_matches([])
        stub_request(:get, "#{api_base}/matches/1").to_return(status: 500, body: 'oops')

        expect { @checker.check }.to change { @checker.events.count }.by(1)
        expect(@checker.events.last.payload['confirmed']).to be false
        expect(@checker.error_logs).not_to be_empty
      end
    end

    describe 'error handling' do
      it 'logs an error and emits nothing on an API error response' do
        stub_request(:get, "#{api_base}/matches?status=live")
          .to_return(status: 500, body: 'internal error')

        expect { @checker.check }.not_to raise_error
        expect(@checker.events).to be_empty
        expect(@checker.error_logs.last).to include('HTTP 500')
        expect(@checker.memory).not_to have_key('primed_live')
      end

      it 'logs an error and emits nothing on an invalid key (401)' do
        stub_request(:get, "#{api_base}/matches?status=live")
          .to_return(status: 401, body: { 'error' => 'unauthorized' }.to_json)

        expect { @checker.check }.not_to raise_error
        expect(@checker.error_logs.last).to include('HTTP 401')
      end

      it 'logs an error and emits nothing when rate limited (429)' do
        stub_request(:get, "#{api_base}/matches?status=live")
          .to_return(status: 429, body: { 'error' => 'rate_limited' }.to_json)

        expect { @checker.check }.not_to raise_error
        expect(@checker.error_logs.last).to include('HTTP 429')
      end

      it 'logs an error and emits nothing on a network failure' do
        stub_request(:get, "#{api_base}/matches?status=live").to_raise(SocketError.new('no route'))

        expect { @checker.check }.not_to raise_error
        expect(@checker.events).to be_empty
        expect(@checker.error_logs.last).to include('SocketError')
      end

      it 'logs an error and emits nothing on unparseable JSON' do
        stub_request(:get, "#{api_base}/matches?status=live")
          .to_return(status: 200, body: 'not json at all {')

        expect { @checker.check }.not_to raise_error
        expect(@checker.events).to be_empty
        expect(@checker.error_logs.last).to include('unparseable JSON')
      end

      it 'does not clobber tracked state when a later poll fails' do
        stub_live_matches([match_fixture(id: 1)])
        @checker.check
        stub_request(:get, "#{api_base}/matches?status=live").to_return(status: 500)

        @checker.check
        expect(@checker.memory['matches']).to have_key('1')
      end
    end
  end

  describe 'break-point derivation' do
    def bp(**kwargs)
      @checker.send(:break_point?, match_fixture(id: 1, **kwargs)['score'])
    end

    it 'is true when the receiver is at AD' do
      expect(bp(points: %w[40 AD], server: 1)).to be true
    end

    it 'is true when the receiver is at 40 and the server at 0/15/30' do
      expect(bp(points: %w[0 40], server: 1)).to be true
      expect(bp(points: %w[15 40], server: 1)).to be true
      expect(bp(points: %w[30 40], server: 1)).to be true
      expect(bp(points: %w[40 30], server: 2)).to be true
    end

    it 'is false at deuce (40-40)' do
      expect(bp(points: %w[40 40], server: 1)).to be false
    end

    it 'is false when the server is ahead or at AD' do
      expect(bp(points: %w[AD 40], server: 1)).to be false
      expect(bp(points: %w[40 15], server: 1)).to be false
    end

    it 'is never derived in a tiebreak' do
      expect(bp(points: %w[6 5], server: 1, is_tiebreak: true)).to be false
    end

    it 'is nil when the server is unknown' do
      expect(bp(points: %w[15 40], server: nil)).to be_nil
    end

    it 'is nil when a point entry is null' do
      expect(bp(points: ['15', nil], server: 1)).to be_nil
    end

    it 'is nil when the score itself is null' do
      expect(@checker.send(:break_point?, nil)).to be_nil
    end
  end

  describe '#check in fixtures mode' do
    before do
      @checker.options = @valid_options.merge('mode' => 'fixtures')
    end

    it 'primes memory on the first check without emitting events' do
      stub_fixtures([fixture_fixture(id: 100), fixture_fixture(id: 101)])
      expect { @checker.check }.not_to change { @checker.events.count }
      expect(@checker.memory['fixtures'].keys).to match_array(%w[100 101])
    end

    context 'once primed' do
      before do
        stub_fixtures([fixture_fixture(id: 100, start_time: nil)])
        @checker.check
      end

      it 'emits new_fixture when a fixture appears' do
        stub_fixtures([fixture_fixture(id: 100, start_time: nil), fixture_fixture(id: 200)])
        expect { @checker.check }.to change { @checker.events.count }.by(1)

        payload = @checker.events.last.payload
        expect(payload['event_type']).to eq 'new_fixture'
        expect(payload['fixture']['id']).to eq 200
      end

      it 'emits fixture_updated when the order of play assigns a start time' do
        stub_fixtures([fixture_fixture(id: 100, start_time: '2026-08-18T14:30:00Z')])
        expect { @checker.check }.to change { @checker.events.count }.by(1)

        payload = @checker.events.last.payload
        expect(payload['event_type']).to eq 'fixture_updated'
        expect(payload['fixture']['start_time']).to eq '2026-08-18T14:30:00Z'
        expect(payload['previous_start_time']).to be_nil
      end

      it 'emits no events when nothing changed' do
        stub_fixtures([fixture_fixture(id: 100, start_time: nil)])
        expect { @checker.check }.not_to change { @checker.events.count }
      end
    end

    it 'logs an error and emits nothing on an API error response' do
      stub_request(:get, "#{api_base}/fixtures").to_return(status: 503, body: 'down')

      expect { @checker.check }.not_to raise_error
      expect(@checker.events).to be_empty
      expect(@checker.error_logs.last).to include('HTTP 503')
    end
  end
end
