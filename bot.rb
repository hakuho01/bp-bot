# gem読み込み
require 'discordrb'
require 'dotenv'
require 'pg'
require 'sequel'
require 'net/http'
require 'uri'
require 'json'
require 'time'

# 環境変数読み込み
Dotenv.load
CLIENT_ID = ENV['CLIENT_ID']
TOKEN = ENV['TOKEN']
DB_URL = ENV['DB_URL']
ROLE_ID = (ENV['ROLE_ID'] || '').to_i

# botインスタンス作成
bot = Discordrb::Bot.new(client_id: CLIENT_ID, token: TOKEN)

# データベースとの接続確立
DB = Sequel.connect(DB_URL)

# JST関連ヘルパー
def jst_now
  Time.now.getlocal('+09:00')
end

def current_year_month
  now = jst_now
  sprintf('%04d%02d', now.year, now.month)
end

# クラバト日インデックス（毎日5:00区切り）
def current_day_index
  now = jst_now
  # 5時間前の日付を取得（5:00〜4:59が1日）
  adjusted_time = now - 5 * 60 * 60
  adjusted_time.day
end

def channel_to_boss_number(channel_id)
  row = DB[:channel_mappings].where(channel_id: channel_id).first
  row && row[:boss_number]
end

def level_for_laps(laps)
  case laps
  when 1..7 then 2
  when 8..22 then 3
  else 4
  end
end

PANEL_MESSAGE_IDS = {}

# パネルメッセージIDの永続化
def save_panel_message_id(channel_id, message_id)
  existing = DB[:panel_messages].where(channel_id: channel_id).first
  if existing
    DB[:panel_messages].where(id: existing[:id]).update(
      message_id: message_id,
      updated_at: Time.now
    )
  else
    DB[:panel_messages].insert(
      channel_id: channel_id,
      message_id: message_id,
      created_at: Time.now,
      updated_at: Time.now
    )
  end
end

# 起動時にパネルメッセージIDを復元
def restore_panel_messages
  DB[:panel_messages].each do |row|
    PANEL_MESSAGE_IDS[row[:channel_id]] = row[:message_id]
  end
end

def max_hp_for(boss_state)
  # 段階レベルに応じて max_hp_lv{2,3,4} を使用
  laps = boss_state[:laps].to_i
  level = (boss_state[:level] || level_for_laps(laps)).to_i
  level_key = "max_hp_lv#{level}".to_sym
  
  # 段階別HPを使用
  boss_state[level_key] || 0
end

def build_panel_payload(channel_id)
  ch = channel_to_boss_number(channel_id)
  return nil unless ch
  boss_data = DB[:boss_states].where(year_month: current_year_month, boss_number: ch).first
  return nil unless boss_data
  laps = boss_data[:laps]
  level = boss_data[:level]
  attacked_users, attacking_users = fetch_attack_status_strings(ch, laps)
  attacked_users = attacked_users.to_s
  attacking_users = attacking_users.to_s
  max_hp = max_hp_for(boss_data)
  {
    "content": '',
    "tts": false,
    "embeds": [
      {
        "id": 652627557,
        "title": "【#{ch}ボス】#{(boss_data[:name] rescue nil) || "ボス名未設定"} #{boss_data[:now_hp]}万/#{max_hp}万",
        "description": "**凸済み**\n#{attacked_users}\n\n**凸中**\n#{attacking_users}",
        "color": 2326507,
        "fields": [],
        "author": { "name": "#{laps}周目【#{level}段階】" }
      }
    ],
    components: [
      {
        type: 1,
        components: [
          { type: 2, label: '通常凸', style: 1, custom_id: "atk/#{current_year_month}/#{ch}/#{laps}" },
          { type: 2, label: '持越凸', style: 1, custom_id: "over/#{current_year_month}/#{ch}/#{laps}" },
          { type: 2, label: '完了',   style: 3, custom_id: "comp/#{current_year_month}/#{ch}/#{laps}" },
          { type: 2, label: '討伐',   style: 3, custom_id: "beat/#{current_year_month}/#{ch}/#{laps}" }
        ]
      }
    ]
  }
end

def post_or_update_panel(channel_id)
  payload = build_panel_payload(channel_id)
  return unless payload
  uri_base = "https://discordapp.com/api/channels/#{channel_id}/messages"
  http = Net::HTTP.new('discordapp.com', 443)
  http.use_ssl = true
  headers = { 'Content-Type' => 'application/json', 'Authorization' => "Bot #{TOKEN}" }
  message_id = PANEL_MESSAGE_IDS[channel_id]
  if message_id
    # PATCH で更新
    uri = URI.parse("#{uri_base}/#{message_id}")
    request = Net::HTTP::Patch.new(uri.request_uri, headers)
    request.body = payload.to_json
    response = http.request(request)
    unless response.is_a?(Net::HTTPSuccess)
      # 失敗したら新規投稿を試す
      uri = URI.parse(uri_base)
      resp = http.post(uri.request_uri, payload.to_json, headers)
      if resp.is_a?(Net::HTTPSuccess)
        body = JSON.parse(resp.body) rescue {}
        new_message_id = body['id']
        PANEL_MESSAGE_IDS[channel_id] = new_message_id
        save_panel_message_id(channel_id, new_message_id)
      end
    end
  else
    uri = URI.parse(uri_base)
    resp = http.post(uri.request_uri, payload.to_json, headers)
    if resp.is_a?(Net::HTTPSuccess)
      body = JSON.parse(resp.body) rescue {}
      new_message_id = body['id']
      PANEL_MESSAGE_IDS[channel_id] = new_message_id
      save_panel_message_id(channel_id, new_message_id)
    end
  end
end

def post_new_panel(channel_id)
  payload = build_panel_payload(channel_id)
  return unless payload
  http = Net::HTTP.new('discordapp.com', 443)
  http.use_ssl = true
  headers = { 'Content-Type' => 'application/json', 'Authorization' => "Bot #{TOKEN}" }
  uri = URI.parse("https://discordapp.com/api/channels/#{channel_id}/messages")
  resp = http.post(uri.request_uri, payload.to_json, headers)
  if resp.is_a?(Net::HTTPSuccess)
    body = JSON.parse(resp.body) rescue {}
    new_message_id = body['id']
    PANEL_MESSAGE_IDS[channel_id] = new_message_id
    save_panel_message_id(channel_id, new_message_id)
  end
end

def format_damage(d)
  (d || 0).to_i
end

def build_daily_status_panel
  today = current_day_index
  members = DB[:members].where(is_member: true).order(:discord_user_name).all
  
  lines = []
  members.each do |member|
    # a: その日の通常凸完了回数（carry_over=false の completed・killed）
    normal_completed = DB[:attacks].where(
      member_id: member[:id],
      year_month: current_year_month,
      day_index: today,
      carry_over: false,
      status: ['completed', 'killed']
    ).count
    
    # c: その日の持ち越し凸完了回数（carry_over=true の completed・killed）
    carry_over_completed = DB[:attacks].where(
      member_id: member[:id],
      year_month: current_year_month,
      day_index: today,
      carry_over: true,
      status: ['completed', 'killed']
    ).count
    
    # d: その日の獲得持ち越し回数（carry_over=false の killed）
    earned_carry_over = DB[:attacks].where(
      member_id: member[:id],
      year_month: current_year_month,
      day_index: today,
      carry_over: false,
      status: 'killed'
    ).count
    
    display_name = member[:display_name] || member[:discord_user_name]
    lines << "#{display_name}　#{normal_completed}/3　#{carry_over_completed}/#{earned_carry_over}"
  end
  
  {
    "content": '',
    "tts": false,
    "embeds": [
      {
        "title": "#{jst_now.strftime('%Y年%m月%d日')}凸状況",
        "description": lines.join("\n"),
        "color": 3447003,
        "fields": [],
        "timestamp": jst_now.iso8601
      }
    ]
  }
end

def post_daily_status(channel_id)
  payload = build_daily_status_panel
  return unless payload
  
  http = Net::HTTP.new('discordapp.com', 443)
  http.use_ssl = true
  headers = { 'Content-Type' => 'application/json', 'Authorization' => "Bot #{TOKEN}" }
  uri = URI.parse("https://discordapp.com/api/channels/#{channel_id}/messages")
  resp = http.post(uri.request_uri, payload.to_json, headers)
  resp.is_a?(Net::HTTPSuccess)
end

def fetch_attack_status_strings(boss_number, laps)
  # 凸中（宣言中）
  attacking_rows = DB[:attacks]
    .join(:members, id: :member_id)
    .where(year_month: current_year_month, boss_number: boss_number, laps_at_start: laps, status: 'declared', is_attacking: true)
    .select(Sequel[:members][:display_name].as(:display_name), Sequel[:members][:discord_user_name].as(:discord_user_name), Sequel[:attacks][:damage].as(:damage))
    .all

  # 凸済み（完了、討伐含む）
  attacked_rows = DB[:attacks]
    .join(:members, id: :member_id)
    .where(year_month: current_year_month, boss_number: boss_number, laps_at_start: laps, status: 'completed')
    .select(Sequel[:members][:display_name].as(:display_name), Sequel[:members][:discord_user_name].as(:discord_user_name), Sequel[:attacks][:damage].as(:damage))
    .all

  attacking_str = attacking_rows.map { |r| "#{(r[:display_name] || r[:discord_user_name])} #{format_damage(r[:damage])}万" }.join("\n")
  attacked_str = attacked_rows.map { |r| "#{(r[:display_name] || r[:discord_user_name])} #{format_damage(r[:damage])}万" }.join("\n")
  [attacked_str, attacking_str]
end

# コマンド: cb_start（現在のチャンネルに凸パネルを投稿）
bot.message(contains: 'cb_start') do |event|
  begin
    rows = DB[:channel_mappings].all
    if rows.empty?
      event.respond 'channel_mappings が空なの（チャンネル紐付けを登録してほしいの）'
      next
    end
    posted = 0
    rows.each do |r|
      boss_number = r[:boss_number]
      state = DB[:boss_states].where(year_month: current_year_month, boss_number: boss_number).first
      next unless state
      post_new_panel(r[:channel_id])
      posted += 1
    end
  rescue => e
    event.respond "パネル一括投稿でエラーなの: #{e.class} #{e.message}"
  end
end

# ダメージ入力受付
bot.message do |event|
  messaged_user = get_user(event.user.id)
  next unless messaged_user

  # 待機状態（宣言中）の攻撃のみ受理
  attacking_data = DB[:attacks].where(member_id: messaged_user[:id], is_attacking: true, status: 'declared').first
  next unless attacking_data

  content = event.message.content.to_s.strip
  # 半角数字のみ受理（それ以外が含まれる場合は無視）
  next unless content.match?(/^[0-9]+$/)

  damage_val = content.to_i
  DB[:attacks].where(id: attacking_data[:id]).update(damage: damage_val, updated_at: Sequel::CURRENT_TIMESTAMP)
  # 入力のたび即時更新
  begin
    post_or_update_panel(event.channel.id)
    # 凸状況パネルも更新
    status_channel_id = ENV['STATUS_CHANNEL_ID']
    if status_channel_id && !status_channel_id.strip.empty?
      post_daily_status(status_channel_id.to_i)
    end
  rescue => e
    # 失敗しても黙って続行
  end
end

def safe_defer(event)
  begin
    event.defer_update
  rescue => _
  end
end

bot.button do |event|
  begin
    # Interactionは3秒以内に応答が必要。最初に必ずdeferする
    safe_defer(event)

    btn_id_ary = event.custom_id.split('/') # ['atk','202411','1','1']
    unless btn_id_ary.size >= 4
      bot.send_message(event.channel.id, "ボタンの形式が不正なの")
      next
    end
    unless btn_id_ary[1] == current_year_month # 不正な年月のボタンは無視
      bot.send_message(event.channel.id, "古いボタンなの。最新の状況で操作してほしいの")
      next
    end

    user = get_user(event.user.id)
    unless user
      bot.send_message(event.channel.id, "<@!#{event.user.id}>メンバー登録が必要なの。'add_user' を送って登録してほしいの")
      next
    end

    case btn_id_ary[0]
    when 'atk' # 通常凸時
    if DB[:attacks].where(member_id: user[:id], is_attacking: true, status: 'declared').first
      bot.send_message(event.channel.id, "<@!#{event.user.id}>他のボスに凸してるの。先に完了してほしいの")
    else
      boss_number = btn_id_ary[2].to_i
      boss_state = DB[:boss_states].where(year_month: current_year_month, boss_number: boss_number).first
      unless boss_state
        bot.send_message(event.channel.id, "ボスの状態が見つからないの")
      else
        DB[:attacks].insert(
          year_month: current_year_month,
          day_index: current_day_index,
          member_id: user[:id],
          boss_number: boss_number,
          laps_at_start: boss_state[:laps],
          level_at_start: boss_state[:level],
          is_attacking: true,
          damage: 0,
          carry_over: false,
          counts_consumption: false,
          status: 'declared'
        )
        post_or_update_panel(event.channel.id)
        # 凸状況パネルも更新
        status_channel_id = ENV['STATUS_CHANNEL_ID']
        if status_channel_id && !status_channel_id.strip.empty?
          post_daily_status(status_channel_id.to_i)
        end
      end
    end
    when 'over' # 持ち越し凸時
    if DB[:attacks].where(member_id: user[:id], is_attacking: true, status: 'declared').first
      bot.send_message(event.channel.id, "<@!#{event.user.id}>他のボスに凸してるの。先に完了してほしいの")
    else
      boss_number = btn_id_ary[2].to_i
      boss_state = DB[:boss_states].where(year_month: current_year_month, boss_number: boss_number).first
      unless boss_state
        bot.send_message(event.channel.id, "ボスの状態が見つからないの")
      else
        DB[:attacks].insert(
          year_month: current_year_month,
          day_index: current_day_index,
          member_id: user[:id],
          boss_number: boss_number,
          laps_at_start: boss_state[:laps],
          level_at_start: boss_state[:level],
          is_attacking: true,
          damage: 0,
          carry_over: true,
          counts_consumption: false,
          status: 'declared'
        )
        post_or_update_panel(event.channel.id)
        # 凸状況パネルも更新
        status_channel_id = ENV['STATUS_CHANNEL_ID']
        if status_channel_id && !status_channel_id.strip.empty?
          post_daily_status(status_channel_id.to_i)
        end
      end
    end
    when 'comp' # 凸完了時
    attacking_info = DB[:attacks].where(member_id: user[:id], is_attacking: true, status: 'declared').first
    if !attacking_info
      bot.send_message(event.channel.id, "<@!#{event.user.id}>凸宣言が無いのね")
    else
      DB[:attacks].where(id: attacking_info[:id]).update(
        is_attacking: false,
        status: 'completed',
        counts_consumption: true,
        completed_at: Time.now
      )
      # ボスHPを減算
      state = DB[:boss_states].where(year_month: current_year_month, boss_number: attacking_info[:boss_number]).first
      if state
        new_hp = state[:now_hp].to_i - attacking_info[:damage].to_i
        new_hp = 0 if new_hp < 0
        DB[:boss_states].where(id: state[:id]).update(now_hp: new_hp, updated_at: Time.now)
      end
      post_or_update_panel(event.channel.id)
      # 凸状況パネルも更新
      status_channel_id = ENV['STATUS_CHANNEL_ID']
      if status_channel_id && !status_channel_id.strip.empty?
        post_daily_status(status_channel_id.to_i)
      end
    end
    when 'beat' # 討伐時
    boss_number = btn_id_ary[2].to_i
    laps_clicked = btn_id_ary[3].to_i
    state = DB[:boss_states].where(year_month: current_year_month, boss_number: boss_number).first
    unless state
      bot.send_message(event.channel.id, "ボスの状態が見つからないの")
      next
    end
    if state[:laps].to_i != laps_clicked
      bot.send_message(event.channel.id, "古い討伐ボタンなの。最新の状況で操作してほしいの")
      next
    end

    # ユーザーが該当ボスで宣言中なら討伐扱いにする（同一ボス・同一周回のみ対象）
    declared_ds = DB[:attacks].where(
      member_id: user[:id],
      boss_number: boss_number,
      laps_at_start: state[:laps],
      is_attacking: true,
      status: 'declared'
    )
    if declared_ds.count > 0
      declared_ds.update(
        is_attacking: false,
        status: 'killed',
        counts_consumption: true,
        completed_at: Time.now
      )
    end

    # 周回+1、段階再計算、HPリセット
    new_laps = state[:laps].to_i + 1
    new_level = level_for_laps(new_laps)
    next_max_hp = begin
      # 次周の段階での最大HPを計算
      tmp = state.dup
      tmp[:laps] = new_laps
      tmp[:level] = new_level
      max_hp_for(tmp)
    end
    DB[:boss_states].where(id: state[:id]).update(
      laps: new_laps,
      level: new_level,
      now_hp: next_max_hp,
      updated_at: Time.now
    )

    # 次周のパネルを新規投稿
    post_new_panel(event.channel.id)
    # 凸状況パネルも更新
    status_channel_id = ENV['STATUS_CHANNEL_ID']
    if status_channel_id && !status_channel_id.strip.empty?
      post_daily_status(status_channel_id.to_i)
    end
  end

  rescue => e
    bot.send_message(event.channel.id, "エラーが発生したの: #{e.class} #{e.message}")
  end
end

# ユーザー手動追加メソッド
bot.message(contains: 'add_user') do |event|
  begin
    # event.user から直接情報を取得
    display = event.user.display_name || event.user.username
    
    # 既存ユーザーかチェック
    existing = DB[:members].where(discord_user_id: event.user.id).first
    if existing
      # 既存ユーザーの場合は更新
      DB[:members].where(id: existing[:id]).update(
        discord_user_name: event.user.username,
        display_name: display,
        is_member: true,
        updated_at: Time.now
      )
      event.respond "ユーザー情報を更新したの: #{display}"
    else
      # 新規ユーザーの場合は登録
      DB[:members].insert(
        discord_user_id: event.user.id,
        discord_user_name: event.user.username,
        display_name: display,
        is_member: true,
        created_at: Time.now,
        updated_at: Time.now
      )
      event.respond "登録したの: #{display}"
    end
  rescue => e
    event.respond "登録でエラーなの: #{e.class} #{e.message}"
  end
end

# 凸状況パネル投稿コマンド
bot.message(contains: 'status') do |event|
  begin
    post_daily_status(event.channel.id)
  rescue => e
    event.respond "凸状況パネル投稿でエラーなの: #{e.class} #{e.message}"
  end
end

# ボス追加コマンド: add_boss 1 ネプテリオン 2000 5000 12000
bot.message(contains: 'add_boss') do |event|
  begin
    parts = event.message.content.split
    if parts.size != 6
      event.respond "使い方: add_boss ボス番号 ボス名 2段階HP 3段階HP 4段階HP"
      next
    end
    
    boss_number = parts[1].to_i
    boss_name = parts[2]
    hp_lv2 = parts[3].to_i
    hp_lv3 = parts[4].to_i
    hp_lv4 = parts[5].to_i
    
    unless (1..5).include?(boss_number)
      event.respond "ボス番号は1〜5の範囲で指定してほしいの"
      next
    end
    
    # 当月のボスデータを更新または作成
    existing = DB[:boss_states].where(year_month: current_year_month, boss_number: boss_number).first
    if existing
      DB[:boss_states].where(id: existing[:id]).update(
        name: boss_name,
        max_hp_lv2: hp_lv2,
        max_hp_lv3: hp_lv3,
        max_hp_lv4: hp_lv4,
        now_hp: hp_lv2,  # 初期値は2段階目
        level: 2,        # 初期値は2段階
        laps: 1,         # 初期値は1周目
        updated_at: Time.now
      )
      event.respond "ボス#{boss_number}のデータを更新したの: #{boss_name}"
    else
      DB[:boss_states].insert(
        year_month: current_year_month,
        boss_number: boss_number,
        name: boss_name,
        max_hp_lv2: hp_lv2,
        max_hp_lv3: hp_lv3,
        max_hp_lv4: hp_lv4,
        now_hp: hp_lv2,  # 初期値は2段階目
        level: 2,        # 初期値は2段階
        laps: 1,         # 初期値は1周目
        created_at: Time.now,
        updated_at: Time.now
      )
      event.respond "ボス#{boss_number}のデータを作成したの: #{boss_name}"
    end
  rescue => e
    event.respond "ボス追加でエラーなの: #{e.class} #{e.message}"
  end
end

# コマンド: sync_members（ロール所持者をDBに同期）
bot.message(contains: 'sync_members') do |event|
  begin
    if ROLE_ID == 0
      event.respond 'ROLE_ID が設定されていないの（.env に ROLE_ID= を設定してほしいの）'
      next
    end
    server = event.server
    unless server
      event.respond 'サーバ情報が取得できないの'
      next
    end
    role = server.role(ROLE_ID)
    unless role
      event.respond "ロールが見つからないの（ROLE_ID=#{ROLE_ID}）"
      next
    end

    # いったん全メンバーを非アクティブ化
    DB[:members].update(is_member: false)

    synced = 0
    role.members.each do |m|
      existing = DB[:members].where(discord_user_id: m.id).first
      if existing
        DB[:members].where(id: existing[:id]).update(
          discord_user_name: m.username,
          display_name: (m.display_name || m.username),
          is_member: true,
          updated_at: Sequel::CURRENT_TIMESTAMP
        )
      else
        DB[:members].insert(
          discord_user_id: m.id,
          discord_user_name: m.username,
          display_name: (m.display_name || m.username),
          is_member: true,
          created_at: Sequel::CURRENT_TIMESTAMP,
          updated_at: Sequel::CURRENT_TIMESTAMP
        )
      end
      synced += 1
    end

    event.respond "メンバー同期が完了したの（#{synced} 人）"
  rescue => e
    event.respond "メンバー同期でエラーなの: #{e.class} #{e.message}"
  end
end

# 起動時DBから情報取ってアクティブな週目とかの情報を変数にいれる　じゃないと途中で再起動したとき死ぬので
# クランバトル開始コマンド → メンバー取得、登録
# 毎日5時 → 凸管理ポスト

# ユーザー取得メソッド
def get_user(id)
  DB[:members].where(discord_user_id: id).first
end

# 起動時にパネルメッセージIDを復元
restore_panel_messages

# 定期投稿（毎朝5時）
Thread.new do
  loop do
    now = jst_now
    # 5時ちょうどに投稿
    next_5am = Time.new(now.year, now.month, now.day, 5, 0, 0, '+09:00')
    next_5am += 24 * 60 * 60 if next_5am <= now
    
    sleep_time = next_5am - now
    sleep(sleep_time)
    
    begin
      # 凸状況チャンネルID（環境変数で指定）
      status_channel_id = ENV['STATUS_CHANNEL_ID']
      if status_channel_id && !status_channel_id.strip.empty?
        post_daily_status(status_channel_id.to_i)
      else
        puts "STATUS_CHANNEL_ID が設定されていません"
      end
    rescue => e
      puts "定期投稿でエラー: #{e.class} #{e.message}"
    end
  end
end

bot.run
