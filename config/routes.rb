# frozen_string_literal: true

RedmineApp::Application.routes.draw do
  get  'inapp_notifications',           :to => 'inapp_notifications#index',    :as => 'inapp_notifications'
  # Obsah panelu. Vlastná akcia, a NIE `index.json` — prípona `.json` prepne Redmine do
  # API vetvy autentizácie (`api_request?`, application_controller.rb:723), tá ignoruje
  # session cookie a prihlásený človek dostane `Current user: anonymous` a 403.
  # Rovnakú pascu rieši aj redmine_rich_editor u `/uploads.json`.
  get  'inapp_notifications/list',      :to => 'inapp_notifications#list',     :as => 'inapp_notifications_list'
  # Ľahký dotaz na počet neprečítaných — bez načítavania objektov.
  get  'inapp_notifications/state',     :to => 'inapp_notifications#state',    :as => 'inapp_notifications_state'
  post 'inapp_notifications/read_all',  :to => 'inapp_notifications#read_all', :as => 'inapp_notifications_read_all'
  # Až za `read_all`, inak by `:id` pohltilo aj to slovo.
  post 'inapp_notifications/:id/read',  :to => 'inapp_notifications#read',     :as => 'inapp_notification_read',
       :constraints => { :id => /\d+/ }
end
