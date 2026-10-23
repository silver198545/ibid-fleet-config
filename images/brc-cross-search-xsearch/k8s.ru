# Kubernetes用のrackupファイル(アプリ側 config.ru の代わり)。Dockerfileが config/k8s.ru として
# イメージに入れ、puma.rbのrackupで指定する。
#
# Sinatra 4.1以降はdevelopmentモードのときだけHost名を検査し(Rack::Protection::HostAuthorization)、
# localhost・IPアドレス以外のHostを "Host not permitted"(403)で拒否する。devは
# RACK_ENV=developmentで動かすため、Ingressのホスト名(<app>.dev.ibid.lan)を環境変数
# PERMITTED_HOSTS(カンマ区切り。"."で始めるとそのドメイン配下すべて)で許可リストに足す。
# productionモードではSinatraがHost名を検査しないため、この設定は効かない。
#
# また、Rack::Protection::JsonCsrfを無効にする。これは「JSONのレスポンス」かつ「XHRでない」かつ
# 「Refererのホストがリクエストの`Host`と違う」リクエストを "Forbidden"(403)で拒否する。
# 外部nginxはTraefikのルーティングのため`Host`を内部名(<app>.<env>.ibid.lan)に書き換えて転送する
# (`X-Forwarded-Host`はTraefikが上書きする)。そのため公開ドメイン(knowledge.brc.riken.jp)のページから
# fetch()で辞書(/xsearch/catalog/dic/catalog_dic等)を読むと別オリジン扱いになり、オートコンプリートが
# 403で動かない(2026-10-23)。JsonCsrfは古いブラウザでのJSONハイジャック対策で、返すJSONは
# 公開データのため外す。他の保護(セッション関連等)はそのまま残す。
require File.expand_path('../app', __dir__)

extra_hosts = ENV.fetch('PERMITTED_HOSTS', '').split(',').map(&:strip).reject(&:empty?)
if Sinatra::Application.development? && !extra_hosts.empty?
  defaults = Sinatra::Application.host_authorization.fetch(:permitted_hosts, [])
  Sinatra::Application.set :host_authorization, { permitted_hosts: defaults + extra_hosts }
end

if (protection = Sinatra::Application.protection)
  protection = {} unless protection.is_a?(Hash)
  except = Array(protection[:except]) | [:json_csrf]
  Sinatra::Application.set :protection, protection.merge(except: except)
end

run Sinatra::Application
