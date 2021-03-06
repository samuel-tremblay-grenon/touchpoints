require 'sidekiq/web'


Rails.application.routes.draw do
  devise_for :users, controllers: { omniauth_callbacks: 'users/omniauth_callbacks' }

  authenticate :user, lambda { |u| u.admin? } do
    mount Sidekiq::Web => '/admin/sidekiq'
  end

  unless Rails.env.development?
    match "/404", :to => "errors#not_found", :via => :all
    match "/500", :to => "errors#internal_server_error", :via => :all
  end

  resources :forms, only: [:show] do
    member do
      get "js", to: "touchpoints#js", as: :js
      get "submit", to: "submissions#new", form: true, as: :submit
    end
    resources :submissions, only: [:new, :create]
  end

  resources :touchpoints, only: [:show] do
    member do
      get "js", to: "touchpoints#js", as: :js
      get "submit", to: "submissions#new", form: true, as: :submit
    end
    resources :submissions, only: [:new, :create]
  end

  namespace :admin do
    resources :forms do
      member do
        get "notifications", to: "forms#notifications", as: :notifications
        get "example", to: "forms#example", as: :example
        get "export", to: "forms#export", as: :export
        get "export_pra_document", as: :export_pra_document
        get "export_submissions", to: "forms#export_submissions", as: :export_submissions
        get "export_a11_header", to: "forms#export_a11_header", as: :export_a11_header
        get "export_a11_submissions", to: "forms#export_a11_submissions", as: :export_a11_submissions
        get "js", to: "forms#js", as: :js
        get "permissions", to: "forms#permissions", as: :permissions
        get "questions", to: "forms#questions", as: :questions
        get "responses", to: "forms#responses", as: :responses
        post "add_user", to: "forms#add_user", as: :add_user
        post "copy", to: "forms#copy", as: :copy
        post "publish", to: "forms#publish", as: :publish
        delete "remove_user", to: "forms#remove_user", as: :remove_user
      end
      collection do
        post "copy", to: "forms#copy", as: :copy_id
      end
      resources :form_sections
      resources :questions do
        resources :question_options
      end
      resources :submissions, only: [:destroy] do
        member do
          post "flag", to: "submissions#flag", as: :flag
          post "unflag", to: "submissions#unflag", as: :unflag
        end
      end
    end
    resources :users, except: [:new] do
      collection do
        get "deactivate", to: "users#deactivate"
      end
    end
    resources :organizations
    get "dashboard", to: "site#index", as: :dashboard
    get "management", to: "site#management", as: :management
    get "events", to: "site#events", as: :events
    get "events/export", to: "site#events_export", as: :export_events
    root to: "forms#index"
  end

  get "status", to: "site#status", as: :status
  get "index", to: "site#index", as: :index
  root to: redirect("https://touchpoints.digital.gov/")
end
