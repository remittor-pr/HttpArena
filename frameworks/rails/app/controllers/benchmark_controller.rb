# frozen_string_literal: true

require 'zlib'

class BenchmarkController < ActionController::API
  # Pre-load datasets at class level (shared across workers via preload)
  DATASET_PATH = ENV.fetch('DATASET_PATH', '/data/dataset.json')
  LARGE_DATASET_PATH = '/data/dataset-large.json'

  mattr_accessor :dataset_items, :db_available, :large_json_payload
  self.db_available = File.exist?('/data/benchmark.db')

  if File.exist?(DATASET_PATH)
    self.dataset_items = JSON.parse(File.read(DATASET_PATH))
  end

  if File.exist?(LARGE_DATASET_PATH)
    raw = JSON.parse(File.read(LARGE_DATASET_PATH))
    items = raw.map { |d| d.merge('total' => (d['price'] * d['quantity'] * 100).round / 100.0) }
    self.large_json_payload = JSON.generate({ 'items' => items, 'count' => items.length })
  end

  DB_QUERY = 'SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50'

  def pipeline
    render plain: 'ok'
  end

  def baseline11
    total = 0
    request.query_parameters.each_value do |v|
      total += v.to_i
    end
    if request.post?
      body_str = request.body.read.to_s.strip
      total += body_str.to_i
    end
    render plain: total.to_s
  end

  def baseline2
    total = 0
    request.query_parameters.each_value do |v|
      total += v.to_i
    end
    render plain: total.to_s
  end

  def json_endpoint
    if dataset_items
      items = dataset_items.map { |d| d.merge('total' => (d['price'] * d['quantity'] * 100).round / 100.0) }
      body = JSON.generate({ 'items' => items, 'count' => items.length })
      response.headers['Content-Type'] = 'application/json'
      render plain: body
    else
      head 500
    end
  end

  def compression
    if large_json_payload
      sio = StringIO.new
      gz = Zlib::GzipWriter.new(sio, 1)
      gz.write(large_json_payload)
      gz.close
      response.headers['Content-Type'] = 'application/json'
      response.headers['Content-Encoding'] = 'gzip'
      send_data sio.string, disposition: :inline
    else
      head 500
    end
  end

  def db
    unless db_available
      render json: { items: [], count: 0 }
      return
    end

    min_val = (params[:min] || 10).to_f
    max_val = (params[:max] || 50).to_f
    conn = get_db
    rows = conn.execute(DB_QUERY, [min_val, max_val])
    items = rows.map do |r|
      {
        'id' => r['id'], 'name' => r['name'], 'category' => r['category'],
        'price' => r['price'], 'quantity' => r['quantity'], 'active' => r['active'] == 1,
        'tags' => JSON.parse(r['tags']),
        'rating' => { 'score' => r['rating_score'], 'count' => r['rating_count'] }
      }
    end
    render json: { items: items, count: items.length }
  end

  def upload
    data = request.body.read
    render plain: data.bytesize.to_s
  end

  def not_found
    head 404
  end

  private

  def get_db
    Thread.current[:rails_db] ||= begin
      db = SQLite3::Database.new('/data/benchmark.db', readonly: true)
      db.execute('PRAGMA mmap_size=268435456')
      db.results_as_hash = true
      db
    end
  end
end
