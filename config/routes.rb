Rails.application.routes.draw do

  root 'home#show'
  devise_for :users, controllers: { omniauth_callbacks: 'users/omniauth_callbacks' }

  get '/profile' => 'profiles#edit', as: :edit_profile
  patch '/profile' => 'profiles#update'
  get '/my-proposals' => 'proposals#index', as: :proposals

  resources :notifications, only: [:index, :show] do
    post :mark_all_as_read, on: :collection
  end

  resources :events, param: :slug do
    get '/' => 'events#show', as: :event

    post '/proposals' => 'proposals#create', as: :event_proposals

    resources :proposals, param: :uuid do
      member { get :confirm }
      member { post :set_confirmed }
      member { post :withdraw }
      member { delete :destroy }
    end

    get 'parse_edit_field' => 'proposals#parse_edit_field', as: :parse_edit_field_proposal

    #Staff URLS
    namespace 'staff' do
      get '/' => 'events#show'
      get :show

      get :info
      get :edit
      patch :update
      patch 'update-status' => 'events#update_status'
      patch :open_cfp

      get '/config' => 'events#configuration', as: :config
      get 'custom-fields', as: :custom_fields
      put :update_custom_fields
      get 'reviewer-tags', as: :reviewer_tags
      put :update_reviewer_tags
      get 'proposal-tags', as: :proposal_tags
      put :update_proposal_tags

      get :guidelines
      patch :update_guidelines

      get '/speaker-emails' => 'events#speaker_emails', as: :speaker_email_notifications

      resources :teammates, path: 'team'

      # Reviewer flow for proposals
      resources :proposals, controller: 'proposal_reviews', only: [:index, :show, :update], param: :uuid do
        post :rate, defaults: {format: :js}
      end

      scope :program, as: 'program' do
        resources :proposals, param: :uuid do
          collection do
            get 'selection'
            get 'session_counts'
          end
          post :finalize
          post :update_state
          post :update_track
          post :rate, defaults: {format: :js}
        end

        resources :speakers, only: [:index, :show, :edit, :update, :destroy]
        resources :program_sessions, as: 'sessions', path: 'sessions' do
          resources :speakers, only: [:new, :create]
        end
      end

      resources :rooms, only: [:create, :update, :destroy]
      resources :time_slots, except: :show
      resources :session_formats, except: :show
      resources :tracks, except: [:show]

      controller :speakers do
        get :speaker_emails, action: :emails #returns json of speaker emails
      end
    end
  end

  resource :public_comments, only: [:create], controller: :comments, type: 'PublicComment'
  resource :internal_comments, only: [:create], controller: :comments, type: 'InternalComment'

  resources :speakers, only: [:destroy]
  resources :events, only: [:index]

  get 'teammates/:token/accept', :to => 'teammates#accept', as: :accept_teammate
  get 'teammates/:token/decline', :to => 'teammates#decline', as: :decline_teammate

  resources :invitations, only: [:show, :create, :destroy], param: :invitation_slug do
    member do
      get :accept
      get :decline
      get :resend
    end
  end

  namespace 'admin' do
    resources :events, except: [:show, :edit, :update], param: :slug do
      post :archive
      post :unarchive
    end

    resources :users
  end

  get '/current-styleguide', :to => 'pages#current_styleguide'
  get '/404', :to => 'errors#not_found'
  get '/422', :to => 'errors#unacceptable'
  get '/500', :to => 'errors#internal_error'

end
