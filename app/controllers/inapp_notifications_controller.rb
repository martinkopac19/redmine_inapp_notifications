# frozen_string_literal: true

class InappNotificationsController < ApplicationController
  before_action :require_login
  before_action :require_enabled

  # Plná stránka so zoznamom. Zároveň funkčný fallback, keď JS nebeží.
  def index
    @page   = params[:page].to_i.clamp(1, 10_000)
    @limit  = 50
    @offset = (@page - 1) * @limit
    @rows   = present(loader.list(:limit => @limit, :offset => @offset))
    # Ďalšia strana existuje, ak sa vrátil plný počet riadkov. Zámerne bez COUNT —
    # ten by musel prejsť viditeľnosť, teda načítať všetky objekty.
    @more   = @rows.size >= @limit
    InappNotifications.purge_if_due!
  end

  # Obsah panelu pri zvončeku.
  #
  # Samostatná akcia namiesto `index.json`, a nie je to kozmetika: prípona `.json` v URL
  # prepne Redmine do API vetvy (`api_request?`, application_controller.rb:723), tá session
  # cookie ignoruje a prihlásený človek dostane `Current user: anonymous` a HTTP 403.
  # Zistené naživo — panel hlásil „Notifikácie sa nepodarilo načítať".
  def list
    rows = present(loader.list(:limit => InappNotifications.panel_limit))
    InappNotifications.purge_if_due!
    render :json => { :items => rows, :unread => loader.unread_count }
  end

  # Ľahký endpoint pre odznak — bez načítavania objektov.
  # Používa ho obnova na pozadí (fáza 2) aj dorovnanie stavu po reconnecte (fáza 3).
  # ZAKOMENTOVANE 14. 9. 2026: obnova poctu na pozadi (faza 2) ani push (faza 3) sa robit
  # nebudu (rozhodnutie zadavatela), takze endpoint nikto nevola. Kod zostava kvoli tomu, ze
  # ozivenie je lacne: odkomentovat tu, v `config/routes.rb` a v `lib/inapp_notifications/hooks.rb`.
  # def state
  #   render :json => { :unread => InappNotification.unread_count_for(User.current) }
  # end

  def read
    n = InappNotification.for_user(User.current).find_by(:id => params[:id])
    return render(:json => { :error => 'not found' }, :status => :not_found) if n.nil?

    n.update_columns(:read_on => Time.current) unless n.read?
    render :json => { :unread => InappNotification.unread_count_for(User.current) }
  end

  def read_all
    InappNotification.for_user(User.current).unread.update_all(:read_on => Time.current)
    render :json => { :unread => 0 }
  end

  private

  def loader
    @loader ||= InappNotifications::Loader.new(User.current)
  end

  # Dve opatrenia proti dotazom, na ktoré `preload` nedosiahne, lebo nejdú cez asociácie:
  #   * mapa stavov úloh — inak `Journal#event_title` volá `IssueStatus.find_by_id`
  #     na každý riadok (zmerané: +28 dotazov pri 40 journaloch),
  #   * query cache — zachytí zvyšok, napr. `Document#event_author`, ktorý siaha
  #     na `attachments.reorder(...).first`.
  def present(rows)
    statuses = loader.statuses_for(rows)
    ActiveRecord::Base.cache do
      rows.map do |r|
        h = InappNotifications::Presenter.new(r, :statuses => statuses).to_h
        h.merge(:url => path_for(h[:url]))
      end
    end
  end

  # `acts_as_event` vracia URL ako HASH (`{controller:, action:, id:, anchor:}`).
  # Do JSON-u musí ísť hotová cesta — JS ju dáva rovno do `href`, a hash by sa
  # v reťazci vypísal ako „[object Object]" a odkaz by nikam neviedol.
  # Prevádza sa až tu, lebo `url_for` je vec kontroléra, nie presentera.
  def path_for(url)
    return url if url.is_a?(String)
    return nil if url.blank?

    url_for(url.merge(:only_path => true))
  rescue StandardError => e
    Rails.logger&.warn("[inapp_notifications] URL sa nedala zostavit: #{e.class}: #{e.message}")
    nil
  end

  def require_enabled
    return if InappNotifications.enabled?

    render :json => { :error => 'disabled' }, :status => :forbidden
  end
end
