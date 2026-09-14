# frozen_string_literal: true

RedmineApp::Application.routes.draw do
  get  'inapp_notifications',           :to => 'inapp_notifications#index',    :as => 'inapp_notifications'
  # Ľahký dotaz na počet neprečítaných — bez načítavania objektov.
  get  'inapp_notifications/state',     :to => 'inapp_notifications#state',    :as => 'inapp_notifications_state'
  post 'inapp_notifications/read_all',  :to => 'inapp_notifications#read_all', :as => 'inapp_notifications_read_all'
  # Až za `read_all`, inak by `:id` pohltilo aj to slovo.
  post 'inapp_notifications/:id/read',  :to => 'inapp_notifications#read',     :as => 'inapp_notification_read',
       :constraints => { :id => /\d+/ }
end
