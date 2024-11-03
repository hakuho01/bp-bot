# gem読み込み
require 'discordrb'
require 'dotenv'
require 'pg'
require 'sequel'

# 環境変数読み込み
Dotenv.load
CLIENT_ID = ENV['CLIENT_ID']
TOKEN = ENV['TOKEN']
DB_NAME = ENV['DB_NAME']
DB_HOST = ENV['DB_HOST']
DB_USER = ENV['DB_USER']
DB_PASS = ENV['DB_PASS']
DB_PORT = ENV['DB_PORT']

# botインスタンス作成
bot = Discordrb::Bot.new(client_id: CLIENT_ID, token: TOKEN)

# データベースとの接続確立
DB = Sequel.postgres(host: DB_HOST, port: DB_PORT, dbname: DB_NAME, user: DB_USER, password: DB_PASS)
puts DB

bot.message(contains: 'test') do |event|
  req_json = {
    "content": '',
    "tts": false,
    "embeds": [
      {
        "id": 652627557,
        "title": 'ワイバーン 9000万/10000万',
        "description": '**凸済み**
        白鳳　500万
        白鳳　500万

        **凸中**
        白鳳　150万',
        "color": 2326507,
        "fields": [],
        "author": {
          "name": '10周目【2段階】'
        }
      }
    ],
    components: [
      {
        type: 1,
        components: [
          {
            type: 2,
            label: '通常凸',
            style: 1,
            custom_id: 'my_button' # 年月とボス名と週目にする、ex:24年5月の3ボス12周目→b2024050312
          },
          {
            type: 2,
            label: '持越凸',
            style: 1,
            custom_id: 'my_button1'
          },
          {
            type: 2,
            label: '完了',
            style: 3,
            custom_id: 'my_button2'
          },
          {
            type: 2,
            label: '討伐',
            style: 3,
            custom_id: 'my_button3'
          },
        ]
      }
    ]
  }
  uri = URI.parse("https://discordapp.com/api/channels/#{event.channel.id}/messages")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme === 'https'
  params = req_json
  headers = { 'Content-Type' => 'application/json', 'Authorization' => "Bot #{TOKEN}" }
  response = http.post(uri.path, params.to_json, headers)
  begin
    response.value
  rescue => e
    # エラー発生時はエラー内容を白鳳にメンションする
    event.respond "#{e.message} ¥r¥n #{response.body} <@!306022413139705858>"
  end
end

bot.button do |event|
  puts event.custom_id # b2024050312のような形で来る予定なのでフォーマットとバリデートする
  event.defer_update # discord側に何かレスポンスを返さないといけないので
end

# 起動時DBから情報取ってアクティブな週目とかの情報を変数にいれる　じゃないと途中で再起動したとき死ぬので
# クランバトル開始コマンド → メンバー取得、登録
# 毎日5時 → 凸管理ポスト

bot.run
