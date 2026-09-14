# frozen_string_literal: true

class InappNotificationsController < ApplicationController
  before_action :require_login
  before_action :require_enabled

  # Panel aj plná stránka. JSON obsluhuje zvonček, HTML je plnohodnotný zoznam
  # so stránkovaním — a zároveň funkčný fallback, keď JS nebeží.
  def index
    respond_to do |format|
      format.html do
        @limit  = 50
        @offset = (params[:page].to_i.clamp(1, 10_000) - 1) * @limit
        @rows   = present(loader.list(:limit => @limit, :offset => @offset))
        @page   = params[:page].to_i.clamp(1, 10_000)
        # Ďalšia strana existuje, ak sa vrátil plný počet riadkov. Zámerne bez COUNT —
        # ten by musel prejsť viditeľnosť, teda načítať všetky objekty.
        @more   = @rows.size >= @limit
        InappNotifications.purge_if_due!
      end
      format.json do
        rows = present(loader.list(:limit => InappNotifications.panel_limit))
        InappNotifications.purge_if_due!
        render :json => { :items => rows, :unread => loader.unread_count }
      end
    end
  end

  # Ľahký endpoint pre odznak — bez načítavania objektov.
  # Používa ho obnova na pozadí (fáza 2) aj dorovnanie stavu po reconnecte (fáza 3).
  def state
    render :json => { :unread => InappNotification.unread_count_for(User.current) }
  end

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
      rows.map { |r| InappNotifications::Presenter.new(r, :statuses => statuses).to_h }
    end
  end

  def require_enabled
    return if InappNotifications.enabled?

    render :json => { :error => 'disabled' }, :status => :forbidden
  end
end
