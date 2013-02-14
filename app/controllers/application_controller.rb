#
# Copyright 2011 Red Hat, Inc.
#
# This software is licensed to you under the GNU General Public
# License as published by the Free Software Foundation; either version
# 2 of the License (GPLv2) or (at your option) any later version.
# There is NO WARRANTY for this software, express or implied,
# including the implied warranties of MERCHANTABILITY,
# NON-INFRINGEMENT, or FITNESS FOR A PARTICULAR PURPOSE. You should
# have received a copy of GPLv2 along with this software; if not, see
# http://www.gnu.org/licenses/old-licenses/gpl-2.0.txt.

require 'util/threadsession'
require 'util/search'
require 'util/model_util'
require 'cgi'
require 'base64'


class ApplicationController < ActionController::Base
  layout 'katello'
  include Notifications::ControllerHelper
  include Profiling
  clear_helpers

  helper "alchemy/translation"
  helper_method :current_organization
  before_filter :set_locale
  before_filter :require_user,:require_org
  before_filter :check_deleted_org

  protect_from_forgery # See ActionController::RequestForgeryProtection for details

  after_filter :flash_to_headers

  #custom 404 (render_404) and 500 (render_error) pages
  # this is always in the top
  # order of these are important.
  rescue_from Exception do |exception|
    paranoia = Src::Application.config.exception_paranoia

    to_do = case exception
              when StandardError
                :handle
              when ScriptError
                paranoia ? :handle : :raise
              when SignalException, SystemExit, NoMemoryError
                :raise
              else
                Rails.logger.error "Uknown child of Exception instead of StandardError detected: " +
                                       "#{exception.message} (#{exception.class})"
                paranoia ? :handle : :raise
            end

    case to_do
      when :handle
        execute_rescue exception, lambda { |exception| render_error(exception) }
      when :raise
        raise exception
    end
  end

  rescue_from ActiveRecord::RecordInvalid, ActiveRecord::RecordNotSaved  do |e|
    User.current = current_user
    notify.exception e
    log_exception e, :info

    execute_after_filters
    respond_to do |f|
      f.html { render :text => e.to_s, :layout => !request.xhr?, :status => :unprocessable_entity }
      f.json { render :json => e.record.errors, :status => :unprocessable_entity }
    end
    User.current = nil
  end

  rescue_from ActiveRecord::RecordNotFound do |e|
    notify.error e.message
    execute_after_filters
    render :nothing => true, :status => :not_found
  end

  rescue_from ActionController::RoutingError do |exception|
    execute_rescue(exception, lambda{|exception| render_404})
  end

  rescue_from ActionController::UnknownController do |exception|
    execute_rescue(exception, lambda{|exception| render_404})
  end

  rescue_from ActionController::UnknownAction do |exception|
    execute_rescue(exception, lambda{|exception| render_404})
  end

  rescue_from Errors::SecurityViolation do |exception|
    execute_rescue(exception, lambda{|exception| render_403})
  end

  rescue_from HttpErrors::UnprocessableEntity do |exception|
    execute_rescue(exception, lambda{|exception| render_bad_parameters(exception)})
  end
  # support for session (thread-local) variables must be the last filter (except authorize)in this class
  include Katello::ThreadSession::Controller
  include AuthorizationRules
  include Menu

  before_filter :verify_ldap

  def section_id
    'generic'
  end

  # 'default_label' is an action that is used to allow the UI to retrieve
  # a label that is generated by the server based upon a name provided. This action
  # is used by several controllers, but not all.  For those controllers that do
  # use it, the controller will determine if access to it is allowed based on the
  # permissions required by that controller.
  def default_label
    if params[:name]
      render :text => Katello::ModelUtils::labelize(params[:name])
    else
      render :nothing => true
    end
  end

  # this is intentionally dead code, it just mark some strings for gettext
  # so generate_label and default_label_assigned can use them
  def n_gettext_for_generate_label
    # the same string for repository, product, organization, environment (see BZ 886718)
    N_("A label was not provided during repository creation; therefore, a label of '%{label}' was " +
      "automatically assigned. If you would like a different label, please delete the " +
      "repository and recreate it with the desired label.")
    N_("A label was not provided during product creation; therefore, a label of '%{label}' was " +
      "automatically assigned. If you would like a different label, please delete the " +
      "product and recreate it with the desired label.")
    N_("A label was not provided during organization creation; therefore, a label of '%{label}' was " +
      "automatically assigned. If you would like a different label, please delete the " +
      "organization and recreate it with the desired label.")
    N_("A label was not provided during environment creation; therefore, a label of '%{label}' was " +
      "automatically assigned. If you would like a different label, please delete the " +
      "environment and recreate it with the desired label.")
  end

  # Generate a label using the name provided, returning the label and a string with text that may be
  # sent to the user (e.g. via a notice).
  def generate_label object_name, object_type
    # user didn't provide a label, so generate one using the name
    label = Katello::ModelUtils::labelize(object_name)
    # if you modify this string you have to modify it in n_gettext_for_generate_label as well
    label_assigned_text = "A label was not provided during #{object_type} creation; therefore, a label of '%{label}' was " +
      "automatically assigned. If you would like a different label, please delete the " +
      "#{object_type} and recreate it with the desired label."
    label_assigned_text = _(label_assigned_text) % {:label => label}
    return label, label_assigned_text
  end

  # Generate a message that may be sent to the user (e.g. via a notice) to inform them that
  # a label was automatically assigned to the object.
  def default_label_assigned new_object
    object_type = new_object.class.name.downcase
    # if you modify this string you have to modify it in n_gettext_for_generate_label as well
    msg = "A label was not provided during #{object_type} creation; therefore, a label of '%{label}' was " +
      "automatically assigned. If you would like a different label, please delete the " +
      "#{object_type} and recreate it with the desired label."
    return _(msg) % {:label => new_object.label}
  end

  # Generate a message that may be sent to the user (e.g. via a notice) to inform them that
  # the label that they provided has been overriden to ensure uniqueness.
  def label_overridden new_object, requested_label
    object_type = new_object.class.name.downcase
    _("The label requested is already used by another %s; therefore, a unique label was " +
      "assigned.  If you would like a different label, please delete the %s and recreate " +
      "it with a unique label.  Requested label: %s, Assigned label: %s") %
      [object_type, object_type, requested_label, new_object.label]
  end

  def flash_to_headers
    return if @_response.nil? or @_response.response_code == 302
    return if flash.blank?
    [:error, :warning, :success, :message].each do |type|
      unless flash[type].nil? or flash[type].blank?
        @enc = CGI::escape(flash[type].gsub("\n","<br \\>"))
        response.headers['X-Message'] = @enc.gsub("%2B","&#43;")
        response.headers['X-Message-Type'] = type.to_s
        response.headers['X-Message-Request-Type'] = requested_action
        flash.delete(type)  # clear the flash
        return
      end
    end
  end

  def set_locale
    if current_user && current_user.default_locale
      I18n.locale = current_user.default_locale
    else
      I18n.locale = ApplicationController.extract_locale_from_accept_language_header parse_locale
    end

    logger.debug "Setting locale: #{I18n.locale}"
  end

  def current_organization
    unless session[:current_organization_id]
      return nil unless session[:current_organization_id]
    end
    begin
      if @current_org.nil? && current_user
        o = Organization.find(session[:current_organization_id])
        if current_user.allowed_organizations.include?(o)
          @current_org = o
        else
          raise ActiveRecord::RecordNotFound.new _("Permission Denied. User '%{user}' does not have permissions to access organization '%{org}'.") % {:user => User.current.username, :org => o.name}
        end
      end
      return @current_org
    rescue ActiveRecord::RecordNotFound => error
      log_exception error
      session.delete(:current_organization_id)
      org_not_found_error(error)
    end
  end

  def current_organization=(org)
    session[:current_organization_id] = org.try(:id)
  end

  def escape_html input
    CGI::escapeHTML(input)
  end

  helper_method :format_time
  #formats the date time if the dat is not nil
  def format_time  date, options = {}
    return I18n.l(date, options) if date
    ""
  end

  helper_method :no_env_available_msg
  def no_env_available_msg
    _("No environments are currently available in this organization.  Please either add some to the organization or select an organization that has an environment to set user default.")
  end

  # Look for match to list of locales specified in request. If not found, try matching just
  # first two letters. Finally, default to english if no matches at all.
  # eg. [en_US, en] would match en
  # Expects list of locales to search as an array (use parse_locale for that)
  def self.extract_locale_from_accept_language_header locales

    # Look for full match
    locales.each {|locale|
      return locale if Katello.config.available_locales.include? locale
    }

    # Look for match to first two letters
    #
    locales.each {|locale|
      return locale[0..1] if Katello.config.available_locales.include? locale[0..1]
    }

    # Default to 'en'
    return 'en'
  end

  def retain_search_history
    current_user.create_or_update_search_history(URI(@_request.env['HTTP_REFERER']).path, params[:search])
  rescue => error
    log_exception(error)
  end

  private # why bother? methods below are not testable/tested

   def verify_ldap
    u = current_user
    u.verify_ldap_roles if (Katello.config.ldap_roles && u != nil)
  end

  def require_org
    unless session && current_organization
      execute_after_filters
      raise Errors::SecurityViolation, _("User does not belong to an organization.")
    end
  end

  # TODO this check can be removed once we start deleting sessions during org deletion
  def check_deleted_org
    if current_organization && current_organization.being_deleted?
      raise Errors::SecurityViolation, _("Current organization is being deleted, switch to a different one.")
    end
  end

  def matches_no_redirect?(url)
    ["logout", "notices/get_new"].any? {|path| url.include? path}
  end

  def require_user

    if current_user
      #don't redirect if the user is trying to set an org
      if params[:action] != 'set_org' && params[:controller] != 'user_sessions'
        #redirect to originally requested page
        if !session[:original_uri].nil? && !matches_no_redirect?(session[:original_uri])
          redirect_to session[:original_uri]
          session[:original_uri] = nil
        end
      end

      return true
    else
      #user not logged
      notify.warning _("You must be logged in to access that page.")

      #save original uri and redirect to login page
      session[:original_uri] = request.fullpath
      execute_after_filters
      redirect_to new_user_session_url and return false
    end
  end

  def require_no_user
    if current_user
      notify.success _("Welcome Back") + ", " + current_user.username, :persist => false
      execute_after_filters
      redirect_to dashboard_index_url
      return false
    end
  end

  def current_user
    user
  end

  # adapted from http_accept_lang gem, return list of browser locales
  def parse_locale
    locale_lang = (request.env['HTTP_ACCEPT_LANGUAGE'] || '').split(/\s*,\s*/).collect do |l|
      l += ';q=1.0' unless l =~ /;q=\d+\.\d+$/
      l.split(';q=')
    end.sort do |x,y|
      raise "incorrect locale format" unless x.first =~ /^[a-z\-]+$/i
      y.last.to_f <=> x.last.to_f
    end.collect do |l|
      l.first.downcase.gsub(/-[a-z]+$/i) { |x| x.upcase }
    end
  rescue
    []
  end

  # render 403 page
  def render_403
    respond_to do |format|
      format.html { render :template => "common/403", :layout => !request.xhr?, :status => 403 }
      format.atom { head 403 }
      format.xml  { head 403 }
      format.json { head 403 }
    end
    return false
  end

  # render a 404 page
  def render_404(exception = nil)
    if exception
        logger.error _("Rendering 404:") + " #{exception.message}"
    end
    respond_to do |format|
      format.html { render :template => "common/404", :layout => !request.xhr?, :status => 404 }
      format.atom { head 404 }
      format.xml  { head 404 }
      format.json { head 404 }
    end
    User.current = nil
  end

  # render bad params
  def render_bad_parameters(exception)
    if exception
        logger.error _("Rendering 422:") + " #{exception.message}"
        notify.exception(
            _("Invalid parameters sent in the request for this operation. Please contact a system administrator."),
            exception)
    end
    respond_to do |format|
      format.html { render :template => "common/400", :layout => !request.xhr?, :status => exception.status_code }
      format.atom { head exception.status_code }
      format.xml  { head exception.status_code }
      format.json { head exception.status_code }
    end
    User.current = nil
  end


  # take care of 500 pages too
  def render_error(exception = nil)
    if exception
      logger.error _("Rendering 500:") + "#{exception.message}"
      notify.exception exception
    end
    respond_to do |format|
      format.html { render :template => "common/500", :layout => "katello", :status => 500,
                                :locals=>{:error=>exception} }
      format.atom { head 500 }
      format.xml  { head 500 }
      format.json { head 500 }
    end
    User.current = nil
  end

  def requested_action
    unless controller_name.nil? or action_name.nil?
      controller_name + '___' + action_name
    end
  end

  def setup_environment_selector org, accessible
    next_env = KTEnvironment.find(params[:next_env_id]) if params[:next_env_id]

    @paths = []
    @paths = org.promotion_paths.collect{|tmp_path| [org.library] + tmp_path}

    # reject any paths that don't have accessible envs
    @paths.reject!{|path|  (path & accessible).empty?}

    @paths = @paths.sort_by{|p| p[1].name}
    @paths = [[org.library]] if @paths.empty?

    if @environment and !@environment.library?
      @paths.each{|path|
        path.each{|env|
          @path = path and return if env.id == @environment.id
        }
      }
    elsif next_env
      @paths.each{|path|
        path.each{|env|
          @path = path and return if env.id == next_env.id
        }
      }
    else
      @path = @paths.first
      @environment = @path.first
    end
  end

  def environment_path_element(perms_method=nil)
    Proc.new { |a_path| {:id=>a_path.id, :name=>a_path.name, :select=>(perms_method.nil? ? false : a_path.instance_eval(perms_method))} }
  end

  def library_path_element(perms=nil)
    environment_path_element(perms).call(current_organization.library)
  end

  def environment_paths(library, environment_path_element_generator)
    paths = current_organization.promotion_paths
    paths = paths.sort_by{|p| p[0].name}
    to_ret = []
    paths.each do |path|
      path = path.collect{ |e| environment_path_element_generator.call(e) }
      to_ret << [library] + path if path.any?{|e| e[:select]}
    end

    if paths.empty?
      to_ret << [library]
    end

    to_ret
  end


  #verify if the specific object with the given id, matches a given search string
  def search_validate(obj_class, id, search, default=:name)
    obj_class.index.refresh
    search = '*' if search.nil? || search == ''
    search = Katello::Search::filter_input search
    query_options = {}
    query_options[:default_field] = default if default

    results = obj_class.search do
      query { string search, query_options}
      filter :terms, :id=>[id]
    end
    results.total > 0
  end

  # @param [Hash] search_options
  # @option search_options :default_field
  #   The field that should be used by the search engine when a user performs
  #   a search without specifying field.
  # @option search_options :filter
  #   Filter to apply to search. Array of hashes.  Each key/value within the hash
  #   is OR'd, whereas each HASH itself is AND'd together
  # @option search_options [true, false] :load whether or not to load the active record object (defaults to false)
  def render_panel_direct(obj_class, panel_options, search, start, sort, search_options={})

    filters = search_options[:filter] || []
    load = search_options[:load] || false
    all_rows = false
    skip_render = search_options[:skip_render] || false
    page_size = search_options[:page_size] || current_user.page_size

    if search.nil? || search== ''
      all_rows = true
    elsif search_options[:simple_query] && !Katello.config.simple_search_tokens.any?{|s| search.downcase.match(s)}
      search = search_options[:simple_query]
    end
    #search = Katello::Search::filter_input search

    # set the query default field, if one was provided.
    query_options = {}
    query_options[:default_field] = search_options[:default_field] unless search_options[:default_field].blank?

    panel_options[:accessor] ||= "id"
    panel_options[:columns] = panel_options[:col]
    panel_options[:initial_action] ||= :edit

    @items = []

    begin
      results = obj_class.search :load=>false do
        query do
          if all_rows
            all
          else
            string search, query_options
          end
        end

        sort {by sort[0], sort[1].to_s.downcase } unless !all_rows

        filters = [filters] if !filters.is_a? Array
        filters.each{|i|
          filter  :terms, i
        } if !filters.empty?

        size page_size if page_size > 0
        from start
      end

      if load
        @items = obj_class.where(:id=>results.collect{|r| r.id})
        #set total since @items will be just an array
        panel_options[:total_count] = results.empty? ? 0 : results.total
        if @items.length != results.length
          Rails.logger.error("Failed to retrieve all #{obj_class} search results " +
                                 "(#{@items.length}/#{results.length} found.)")
        end
      else
        @items = results
      end

      #get total count
      total = obj_class.search do
        query do
          all
        end
        filters.each{|i|
          filter  :terms, i
        } if !filters.empty?
        size 1
        from 0
      end
      total_count = total.total

    rescue Tire::Search::SearchRequestFailed => e
      Rails.logger.error(e.class)

      total_count = 0
      panel_options[:total_results] = 0
    end
    render_panel_results(@items, total_count, panel_options) if !skip_render
    return @items
  end

  def render_panel_results(results, total, options)
    options[:total_count] ||= results.empty? ? 0 : results.total
    options[:total_results] = total
    options[:collection] = results
    options[:columns] = options[:col]
    @items = results

    if options[:list_partial]
      rendered_html = render_to_string(:partial=>options[:list_partial], :locals=>options)
    elsif options[:render_list_proc]
      rendered_html = options[:render_list_proc].call(@items, options)
    else
      rendered_html = render_to_string(:partial=>"common/list_items", :locals=>options)
    end



    render :json => {:html => rendered_html,
                      :results_count => options[:total_count],
                      :total_items => options[:total_results],
                      :current_items => options[:collection].length }

    retain_search_history unless options[:no_search_history]

  end

  def render_panel_items(items, options, search, start)
    @items = items

    options[:accessor] ||= "id"
    options[:columns] = options[:col]
    options[:initial_action] ||= :edit

    if start == "0"
      options[:total_count] = @items.count
    end

    # the caller may provide items either based on active record or a list within an array... in the case of an
    # array, it is assumed to be based upon results from a pulp/candlepin request, in which case search is
    # not currently supported
    if @items.kind_of? ActiveRecord::Relation
      items_searched = @items.search_for(search)
      items_offset = items_searched.limit(current_user.page_size).offset(start)
    else
      items_searched = @items
      items_offset = items_searched[start.to_i...start.to_i+current_user.page_size]
    end

    options[:total_results] = items_searched.count
    options[:collection] ||= items_offset

    if options[:list_partial]
      rendered_html = render_to_string(:partial=>options[:list_partial], :locals=>options)
    else
      rendered_html = render_to_string(:partial=>"common/list_items", :locals=>options)
    end

    render :json => {:html => rendered_html,
                      :results_count => options[:total_count],
                      :total_items => options[:total_results],
                      :current_items => options[:collection].length }

    retain_search_history
  end

  def execute_after_filters
    flash_to_headers
  end

  def first_env_in_path accessible_envs, include_library=false, organization = current_organization
    return current_organization.library if include_library && accessible_envs.member?(current_organization.library)
    organization.promotion_paths.each{|path|
      path.each{|env|
        if accessible_envs.member?(env)
          return env
        end
      }
    }
    nil
  end

  def execute_rescue exception, renderer
    log_exception exception
    if current_user
      User.current = current_user
      renderer.call(exception)
      User.current = nil
      execute_after_filters
      return false
    else
      notify.warning _("You must be logged in to access that page.")
      execute_after_filters
      redirect_to new_user_session_url and return false
    end
  end

  def org_not_found_error exception
    logger.error exception.message
    execute_after_filters
    logout
    message = _("Your current organization is no longer valid. It is possible that either the organization has been deleted or your permissions revoked, please log back in to continue.")
    notify.warning message
    redirect_to new_user_session_url and return false
  end


  def log_exception exception, level = :error
    logger.send level, "#{exception} (#{exception.class})\n#{exception.backtrace.join("\n")}" if exception
  end

  # Parse the input provided and return the value of displayMessage. If displayMessage is not available, return "".
  # (Note: this can be used to pull the displayMessage from a Candlepin exception.)
  # This assumes that the input follows a syntax similar to:
  #   "{\"displayMessage\":\"Import is older than existing data\"}"
  def self.parse_display_message input
    unless input.nil?
      if input.include? 'displayMessage'
        return JSON.parse(input)['displayMessage']
      end
    end
    input
  end

  def default_notify_options
    { :organization => current_organization }
  end

end

