# Kubernetes用のrackupファイル(アプリ側 config.ru の代わり)。Dockerfileが config/k8s.ru として
# イメージに入れ、puma.rbのrackupで指定する。
#
# Sinatra 4.1以降はdevelopmentモードのときだけHost名を検査し(Rack::Protection::HostAuthorization)、
# localhost・IPアドレス以外のHostを "Host not permitted"(403)で拒否する。devは
# RACK_ENV=developmentで動かすため、Ingressのホスト名(<app>.dev.ibid.lan)を環境変数
# PERMITTED_HOSTS(カンマ区切り。"."で始めるとそのドメイン配下すべて)で許可リストに足す。
# productionモードではSinatraがHost名を検査しないため、この設定は効かない。
require File.expand_path('../app', __dir__)

extra_hosts = ENV.fetch('PERMITTED_HOSTS', '').split(',').map(&:strip).reject(&:empty?)
if Sinatra::Application.development? && !extra_hosts.empty?
  defaults = Sinatra::Application.host_authorization.fetch(:permitted_hosts, [])
  Sinatra::Application.set :host_authorization, { permitted_hosts: defaults + extra_hosts }
end

run Sinatra::Application
