# Kubernetes用のPuma設定(アプリ側 config/puma.rb.template をもとにしたもの)。
# Dockerfileが config/puma.rb としてイメージに入れる。テンプレートとの違い:
#   - stdout_redirect を外し、ログを標準出力に出す(kubectl logsで見るため)
#   - worker数とPumaWorkerKillerのメモリ上限を環境変数で指定する(Deploymentの
#     resources.limits.memoryに合わせる。テンプレートは物理サーバー向けの4worker・6442MB)
#   - activate_control_app を外す(使わないポートを開けない)
#   - rackupはアプリ側 config.ru ではなく config/k8s.ru(同じディレクトリの k8s.ru。
#     developmentモードでのHost名の許可。詳細はk8s.ru冒頭)
root = Dir.getwd
environment ENV.fetch('RACK_ENV', 'production')

bind "tcp://0.0.0.0:#{ENV.fetch('PORT')}"

threads 3, 5
workers Integer(ENV.fetch('WEB_CONCURRENCY', 2))
preload_app!

pidfile "#{root}/tmp/puma/pid"
state_path "#{root}/tmp/puma/state"
rackup "#{root}/config/k8s.ru"

before_fork do
  require 'puma_worker_killer'

  PumaWorkerKiller.config do |config|
    config.ram = Integer(ENV.fetch('PUMA_WORKER_KILLER_RAM_MB', 1024)) # 利用メモリ(MB)
    config.frequency = 30 # 検知秒数
    config.percent_usage = 0.80 # 何％でリスタート？
    config.rolling_restart_frequency = 12 * 3600 # 12時間ごとに再起動する
    config.reaper_status_logs = true

    config.pre_term = -> (worker) { puts "Worker #{worker.inspect} being killed" }
  end

  PumaWorkerKiller.enable_rolling_restart

  PumaWorkerKiller.start
end
