# Ruby 4.0.7 loopback proof for the real async HTTP transport. No provider
# credentials or network calls are used.
abort "Ruby 4.0.7 required, got #{RUBY_VERSION}" unless RUBY_VERSION == '4.0.7'

require 'json'
require 'openssl'
require 'open3'
require 'socket'
require 'timeout'

def check(value, message)
  raise message unless value
end

def serve_connection(socket, state)
  loop do
    request_line = socket.gets
    break if request_line.nil?
    method, path, = request_line.split(' ', 3)
    headers = {}
    while (line = socket.gets)
      break if line == "\r\n" || line == "\n"
      key, value = line.split(':', 2)
      headers[key.downcase] = value.to_s.strip
    end
    body = socket.read(Integer(headers.fetch('content-length', '0'))) || ''
    record = { method: method, path: path, headers: headers, body: body, peer_port: socket.peeraddr[1] }
    state[:mutex].synchronize { state[:requests] << record }

    if path.include?('/probe/concurrent/')
      state[:mutex].synchronize do
        state[:active] += 1
        state[:max_active] = [state[:max_active], state[:active]].max
      end
      sleep 0.04
      state[:mutex].synchronize { state[:active] -= 1 }
    elsif path.end_with?('/channels/accepted/messages')
      sleep 0.15 # Simulates Discord accepting a send but losing its response.
    end

    break if path.end_with?('/probe/disconnect')
    if path.end_with?('/channels/channel-1/messages/pins/message-1')
      socket.write("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n")
    else
      payload = if path.end_with?('/probe/reuse')
        { id: '9007199254740993123', future: { flag: true } }
      elsif path.end_with?('/channels/channel-1/messages')
        { id: 'message-1' }
      elsif path.include?('/probe/concurrent/')
        { id: path.split('/').last }
      else
        { ok: true }
      end
      text = JSON.generate(payload)
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{text.bytesize}\r\nConnection: keep-alive\r\n\r\n#{text}")
    end
  end
rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
  nil
ensure
  socket.close rescue nil
end

def run_probe(binary, mode, port)
  stdout, stderr, status = Open3.capture3(binary, mode, port.to_s)
  check(status.success?, "#{mode} probe failed: #{stderr}#{stdout}")
  stdout.strip
end

state = { mutex: Mutex.new, requests: [], active: 0, max_active: 0 }
server = TCPServer.new('127.0.0.1', 0)
port = server.addr[1]
workers = []
acceptor = Thread.new do
  loop do
    socket = server.accept
    workers << Thread.new(socket) { |connection| serve_connection(connection, state) }
  end
rescue IOError, Errno::EBADF
  nil
end

begin
  binary = File.expand_path(ARGV.fetch(0))
  result = JSON.parse(run_probe(binary, 'http', port))
  check(result.dig('first', 'id') == '9007199254740993123', 'snowflake was not kept as a string')
  check(result.dig('first', 'future', 'flag') == true, 'unknown response fields were dropped')
  check(result.dig('sent', 'id') == 'message-1', 'message response id was not decoded')
  check(result['pinned'].nil?, 'HTTP 204 did not return the empty result')
  sequential = state[:requests].select { |item| item[:path] != '/api/v10/probe/disconnect' }
  check(sequential.map { |item| item[:method] } == %w[GET POST PUT], 'wrong HTTP methods or call order')
  check(sequential.all? { |item| item.dig(:headers, 'authorization') == 'Bot fixture-bot-token' }, 'bot auth missing')
  sent = sequential.find { |item| item[:method] == 'POST' }
  check(JSON.parse(sent[:body]) == { 'content' => 'hello', 'allowed_mentions' => { 'parse' => [] } }, 'POST JSON changed')
  check(sequential.map { |item| item[:peer_port] }.uniq.length == 1, 'keep-alive connection was not reused')
  puts 'PASS methods, auth, JSON, 204, response fields and connection reuse'

  before = state[:requests].length
  run_probe(binary, 'pool', port)
  pool_requests = state[:requests].drop(before).select { |item| item[:path].include?('/probe/concurrent/') }
  check(pool_requests.length == 8, 'connection pool lost a request')
  check(state[:max_active] <= 4, "connection pool exceeded four concurrent requests (#{state[:max_active]})")
  check(state[:max_active] >= 2, 'unrelated routes did not make progress concurrently')
  puts 'PASS four-connection bound and unrelated-route concurrency'

  before = state[:requests].length
  run_probe(binary, 'timeout', port)
  accepted = state[:requests].drop(before).select { |item| item[:path].end_with?('/channels/accepted/messages') }
  check(accepted.length == 1, 'an accepted but timed-out POST was duplicated')
  puts 'PASS one-attempt ambiguous POST timeout'

  before = state[:requests].length
  run_probe(binary, 'disconnect', port)
  disconnected = state[:requests].drop(before).select { |item| item[:path].end_with?('/probe/disconnect') }
  check(disconnected.length == 1, 'disconnected request was not recorded once')
  puts 'PASS disconnected peer is a transport error'
ensure
  server.close
  acceptor.join
  workers.each(&:join)
end

# A self-signed local certificate must fail verification. The helper proves the
# client does not silently disable TLS peer checks.
key = OpenSSL::PKey::RSA.new(2048)
certificate = OpenSSL::X509::Certificate.new
certificate.version = 2
certificate.serial = 1
certificate.subject = OpenSSL::X509::Name.parse('/CN=127.0.0.1')
certificate.issuer = certificate.subject
certificate.public_key = key.public_key
certificate.not_before = Time.now - 60
certificate.not_after = Time.now + 3600
certificate.sign(key, OpenSSL::Digest.new('SHA256'))
tls_server = TCPServer.new('127.0.0.1', 0)
tls_port = tls_server.addr[1]
tls_context = OpenSSL::SSL::SSLContext.new
tls_context.cert = certificate
tls_context.key = key
tls_listener = OpenSSL::SSL::SSLServer.new(tls_server, tls_context)
tls_thread = Thread.new do
  socket = tls_listener.accept
  socket.close
rescue IOError, OpenSSL::SSL::SSLError
  nil
ensure
  tls_server.close rescue nil
end
begin
  run_probe(File.expand_path(ARGV.fetch(0)), 'tls', tls_port)
  puts 'PASS untrusted TLS peer rejected'
ensure
  tls_listener.close rescue nil
  tls_thread.join
end
