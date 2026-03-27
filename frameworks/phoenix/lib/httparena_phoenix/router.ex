defmodule HttparenaPhoenix.Router do
  use Phoenix.Router

  pipeline :bench do
    plug :fetch_query_params
  end

  scope "/", HttparenaPhoenix do
    pipe_through :bench

    get "/pipeline", BenchController, :pipeline
    get "/baseline11", BenchController, :baseline11
    post "/baseline11", BenchController, :baseline11
    get "/baseline2", BenchController, :baseline2
    get "/json", BenchController, :json
    get "/compression", BenchController, :compression
    get "/db", BenchController, :db
    get "/async-db", BenchController, :async_db
    post "/upload", BenchController, :upload
    get "/static/:filename", BenchController, :static_file
  end
end
