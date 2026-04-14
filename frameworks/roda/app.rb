# frozen_string_literal: true

require 'bundler/setup'
Bundler.require(:default)

require 'zlib'

class App < Roda
  SERVER_NAME = 'roda'.freeze

  DATA_DIR = ENV.fetch('DATA_DIR', '/data')
  # Load dataset
  dataset_path = File.join DATA_DIR, 'dataset.json'
  if File.exist?(dataset_path)
    opts[:dataset_items] = JSON.parse(File.read(dataset_path))
  end

  # Load static files into memory
  MIME_TYPES = {
    '.css'   => 'text/css',
    '.js'    => 'application/javascript',
    '.html'  => 'text/html',
    '.woff2' => 'font/woff2',
    '.svg'   => 'image/svg+xml',
    '.webp'  => 'image/webp',
    '.json'  => 'application/json'
  }.freeze

  static_dir = File.join DATA_DIR, 'static'
  opts[:static_files] = {}
  if Dir.exist?(static_dir)
    Dir.foreach(static_dir) do |name|
      next if name == '.' || name == '..'
      path = File.join(static_dir, name)
      next unless File.file?(path)
      ext = File.extname(name)
      ct = MIME_TYPES.fetch(ext, 'application/octet-stream')
      opts[:static_files][name] = { path: path, content_type: ct }
    end
  end
  opts[:static_files].freeze

  PG_QUERY = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3'.freeze

  plugin :default_headers, 'Server' => SERVER_NAME
  plugin :halt
  plugin :request_headers
  plugin :send_file

  route do |r|
    r.root { 'ok' }

    r.is 'pipeline' do
      render_plain 'ok'
    end

    r.is('baseline11') do
      total = 0
      request.GET.each do |_k, v|
        total += v.to_i
      end
      if request.post?
        total += request.body.read.to_i
      end
      render_plain total.to_s
    end

    r.is 'baseline2' do
      total = 0
      request.GET.each do |_k, v|
        total += v.to_i
      end
      render_plain total.to_s
    end

    r.is 'json', Integer do |count|
      dataset = opts[:dataset_items]
      r.halt 500, 'No dataset' unless dataset
      m = (request.params['m'] || 1).to_i
      items = dataset.slice(0, count).map do |d|
        d.merge('total' => (d['price'] * d['quantity'] * m))
      end

      result = JSON.generate({ 'items' => items, 'count' => count })

      if accept_encodings = r.headers['Accept-Encoding']
        type = accept_encodings.split(',').map(&:strip)
        if type.include? 'gzip'
          sio = StringIO.new
          gz = Zlib::GzipWriter.new(sio, 1)
          gz.write(result)
          gz.close
          response[RodaResponseHeaders::CONTENT_ENCODING] = 'gzip'
          result = sio.string
        end
      end
      render_json result
    end

    r.is 'upload' do
      size = 0
      buf = request.body
      while (chunk = buf.read(65536))
        size += chunk.bytesize
      end
      size.to_s
    end

    r.is 'async-db' do
      min_val = (request.params['min'] || 10).to_i
      max_val = (request.params['max'] || 50).to_i
      limit = (request.params['limit'] || 50).to_i.clamp(1, 50)

      rows = self.class.get_async_db&.with do |connection|
        connection.exec_prepared('select', [min_val, max_val, limit])
      end || []

      items = rows.map do |row|
        {
          'id' => row['id'],
          'name' => row['name'],
          'category' => row['category'],
          'price' => row['price'],
          'quantity' => row['quantity'],
          'active' => row['active'] == 1,
          'tags' => JSON.parse(row['tags']),
          'rating' => { 'score' => row['rating_score'], 'count' => row['rating_count'] }
        }
      end
      render_json JSON.generate({ 'items' => items, 'count' => items.length })
    end

    r.on 'static', String do |filename|
      if static_file = opts[:static_files][filename]
        response[RodaResponseHeaders::CONTENT_TYPE] = static_file[:content_type]
        send_file static_file[:path]
      else
        r.halt 404
      end
    end
  end

  private

  def render_json(json)
    response[RodaResponseHeaders::CONTENT_TYPE] = 'application/json'
    json
  end

  def render_plain(plain)
    response[RodaResponseHeaders::CONTENT_TYPE] = 'text/plain'
    plain
  end

  def self.get_async_db
    @async_db ||= begin
      return unless ENV['DATABASE_URL']
      max_connections = ENV.fetch('MAX_THREADS', 4).to_i
      ConnectionPool.new(size: max_connections, timeout: 5) do
        db = PG.connect(ENV['DATABASE_URL'])
        db.prepare('select', PG_QUERY)
        db
      end
    end
  end
end
