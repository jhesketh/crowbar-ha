# Author:: Robert Choi
# Cookbook Name:: pacemaker
# Provider:: primitive
#
# Copyright:: 2013, Robert Choi
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require ::File.join(::File.dirname(__FILE__), *%w(.. libraries cib_objects))

include Chef::Libraries::Pacemaker::CIBObjects

# For vagrant env, switch to the following 'require' command.
#require "/srv/chef/file_store/cookbooks/pacemaker/providers/helper"

action :create do
  name = new_resource.name

  if @current_resource_definition.nil?
    create_resource(name)
  else
    if @current_resource.agent != new_resource.agent
      raise "Existing resource primitive '%s' has agent '%s' " \
            "but recipe wanted '%s'" % \
            [ name, @current_resource.agent, new_resource.agent ]
    end

    modify_resource(name)
  end
end

action :delete do
  name = new_resource.name
  next unless @current_resource
  if pacemaker_resource_running?(name)
    raise "Cannot delete running resource primitive #{name}"
  end
  execute "crm configure delete #{name}" do
    action :nothing
  end.run_action(:run)
  new_resource.updated_by_last_action(true)
  Chef::Log.info "Deleted primitive '#{name}'."
end

action :start do
  name = new_resource.name
  unless @current_resource
    raise "Cannot start non-existent resource primitive '#{name}'"
  end
  next if pacemaker_resource_running?(name)
  execute "crm resource start #{name}" do
    action :nothing
  end.run_action(:run)
  new_resource.updated_by_last_action(true)
  Chef::Log.info "Successfully started primitive '#{name}'."
end

action :stop do
  name = new_resource.name
  unless @current_resource
    raise "Cannot stop non-existent resource primitive '#{name}'"
  end
  next unless pacemaker_resource_running?(name)
  execute "crm resource stop #{name}" do
    action :nothing
  end.run_action(:run)
  new_resource.updated_by_last_action(true)
  Chef::Log.info "Successfully stopped primitive '#{name}'."
end

# Instantiate @current_resource and read details about the existing
# primitive (if any) via "crm configure show" into it, so that we
# can compare it against the resource requested by the recipe, and
# create / delete / modify as necessary.

# http://docs.opscode.com/lwrp_custom_provider_ruby.html#load-current-resource
def load_current_resource
  name = @new_resource.name

  obj_definition = get_cib_object_definition(name)
  return if ! obj_definition or obj_definition.empty?
  Chef::Log.debug "CIB object definition #{obj_definition}"

  unless obj_definition =~ /\Aprimitive #{name} (\S+)/
    Chef::Log.warn "Resource '#{name}' was not a primitive"
    return
  end
  agent = $1

  @current_resource_definition = obj_definition
  @current_resource = Chef::Resource::PacemakerPrimitive.new(name)
  @current_resource.agent(agent)

  %w(params meta).each do |data_type|
    h = extract_hash(name, obj_definition, data_type)
    @current_resource.send(data_type.to_sym, h)
    Chef::Log.debug "detected #{name} has #{data_type} #{h}"
  end
end

def create_resource(name)
  cmd = "crm configure primitive #{name} #{new_resource.agent}"
  cmd << resource_params_string(new_resource.params)
  cmd << resource_meta_string(new_resource.meta)
  cmd << resource_op_string(new_resource.op)

  Chef::Log.info "Creating new resource primitive #{name}"

  execute cmd do
    action :nothing
  end.run_action(:run)

  if cib_object_exists?(name)
    new_resource.updated_by_last_action(true)
    Chef::Log.info "Successfully configured primitive '#{name}'."
  else
    Chef::Log.error "Failed to configure primitive #{name}."
  end
end

def modify_resource(name)
  Chef::Log.info "Checking existing resource primitive #{name} for modifications"

  cmds = []
  modify_params(name, cmds, :params)
  modify_params(name, cmds, :meta)

  cmds.each do |cmd|
    execute cmd do
      action :nothing
    end.run_action(:run)
  end

  new_resource.updated_by_last_action(true) unless cmds.empty?
end

def modify_params(name, cmds, data_type)
  configure_cmd_prefix = "crm_resource --resource #{name}"

  new_resource.send(data_type).each do |param, new_value|
    current_value = @current_resource.send(data_type)[param]
    if current_value == new_value
      Chef::Log.info("#{name}'s #{param} #{data_type} didn't change")
    else
      Chef::Log.info("#{name}'s #{param} #{data_type} changed from #{current_value} to #{new_value}")
      cmd = configure_cmd_prefix + %' --set-parameter "#{param}" --parameter-value "#{new_value}"'
      cmd += " --meta" if data_type == :meta
      cmds << cmd
    end
  end

  @current_resource.send(data_type).each do |param, value|
    unless new_resource.send(data_type).has_key? param
      Chef::Log.info("#{name}'s #{param} #{data_type} was removed")
      cmd = configure_cmd_prefix + %' --delete-parameter "#{param}"'
      cmd += " --meta" if data_type == :meta
      cmds << cmd
    end
  end
end
