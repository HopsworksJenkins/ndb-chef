require File.expand_path(File.dirname(__FILE__) + '/get_ndbapi_addrs')
require File.expand_path(File.dirname(__FILE__) + '/find_mysqld')


case node.platform
when "ubuntu"
 if node.platform_version.to_f <= 14.04
   node.override.ndb.systemd = "false"
 end
end

if node.ndb.systemd == false
   node.override.ndb.systemd = "false"
end  


ndb_connectstring()

if "#{node.ndb.version}.#{node.ndb.majorVersion}".to_f < 7.5
#scripts/mysql_install_db requires perl 
  package "perl" do
    action :install
  end
end

case node.platform_family
when "debian"

  libaio1="libaio1_0.3.109-2ubuntu1_amd64.deb"
  cached_libaio1 = "#{Chef::Config.file_cache_path}/#{libaio1}"
  Chef::Log.info "Installing libaio1 to #{cached_libaio1}"

  cookbook_file cached_libaio1 do
    source libaio1
    owner node.ndb.user
    group node.ndb.group
    mode "0755"
    action :create_if_missing
  end

  package libaio1 do
    provider Chef::Provider::Package::Dpkg
    source cached_libaio1
    action :install
  end

when "rhel"
  package "libaio" do
    action :install
  end
  if "#{node.ndb.version}.#{node.ndb.majorVersion}".to_f < 7.5  
    #scripts/mysql_install_db requires perl-Data-Dumper
    package "perl-Data-Dumper" do
      action :install
    end
  end
 
end

directory node.ndb.mysql_server_dir do
  owner node.ndb.user
  group node.ndb.group
  mode "0755"
  action :create
end

my_ip = my_private_ip()

found_id=find_mysql_id(my_ip)

for script in node.mysql.scripts
  template "#{node.ndb.scripts_dir}/#{script}" do
    source "#{script}.erb"
    owner node.ndb.user
    group node.ndb.group
    mode 0751
    variables({
                :node_id => found_id
              })
  end
end 

pid_file="#{node.ndb.log_dir}/mysql_#{found_id}.pid"


service_name = "mysqld"

if node.ndb.systemd != "true" 

  template "/etc/init.d/#{service_name}" do
    source "#{service_name}.erb"
    owner "root"
    group "root"
    mode 0755
    variables({
                :pid_file => pid_file,
                :node_id => found_id
              })
  end

  service "#{service_name}" do
    provider Chef::Provider::Service::Init::Debian
    supports :restart => true, :stop => true, :start => true, :status => true
    action :nothing
  end


else # sytemd is true

  case node.platform_family
  when "debian"
    systemd_script = "/lib/systemd/system/#{service_name}.service"
  when "rhel"
    systemd_script = "/usr/lib/systemd/system/#{service_name}.service" 
  end

  template systemd_script do
    source "#{service_name}.service.erb"
    owner "root"
    group "root"
    mode 0755
    cookbook 'ndb'
    variables({ :node_id => found_id,
                :pid_file => pid_file
              })
  end


  service "#{service_name}" do
    provider Chef::Provider::Service::Systemd
    supports :restart => true, :stop => true, :start => true, :status => true
    action :nothing
  end

  ndb_start "reload_mysqld" do
    action :systemd_reload
  end

end

mysql_ip = my_ip
if node.mysql.localhost == "true"
  mysql_ip = "localhost"
end

template "mysql.cnf" do
  owner node.ndb.user
  group node.ndb.group
  path "#{node.ndb.root_dir}/my.cnf"
  source "my-ndb.cnf.erb"
  mode "0644"
  variables({
              :mysql_id => found_id,
              :my_ip => mysql_ip
            })
if node.services.enabled == "true"
    notifies :enable, resources(:service => service_name)
end
end


if "#{node.ndb.version}.#{node.ndb.majorVersion}".to_f >= 7.5
    bash 'mysql_install_db_7_5' do
    user "root"
    code <<-EOF
    set -e
    export MYSQL_HOME=#{node.ndb.root_dir}
    # --force causes mysql_install_db to run even if DNS does not work. In that case, grant table entries that normally use host names will use IP addresses.
    cd #{node.mysql.base_dir}
    ./bin/mysqld --defaults-file=#{node.ndb.root_dir}/my.cnf --initialize-insecure --explicit_defaults_for_timestamp
    touch #{node.ndb.mysql_server_dir}/.installed
    # sanity check to set ownership of files to 'mysql' user
    chown -R #{node.ndb.user}:#{node.ndb.group} #{node.ndb.mysql_server_dir}
    EOF
  not_if { ::File.exists?( "#{node.ndb.mysql_server_dir}/.installed" ) }
  end

else
  bash 'mysql_install_db_7_4' do
    user "root"
    code <<-EOF
    set -e
    export MYSQL_HOME=#{node.ndb.root_dir}
    # --force causes mysql_install_db to run even if DNS does not work. In that case, grant table entries that normally use host names will use IP addresses.
    cd #{node.mysql.base_dir}
    ./scripts/mysql_install_db --user=#{node.ndb.user} --basedir=#{node.mysql.base_dir} --defaults-file=#{node.ndb.root_dir}/my.cnf --force 
    touch #{node.ndb.mysql_server_dir}/.installed
    # sanity check to set ownership of files to 'mysql' user
    chown -R #{node.ndb.user} #{node.ndb.mysql_server_dir}
    EOF
  not_if { ::File.exists?( "#{node.ndb.mysql_server_dir}/.installed" ) }
  end
end

ndb_mysql_basic "install" do
  action :nothing
end

grants_path = "#{Chef::Config.file_cache_path}/grants.sql"
template grants_path do
  source File.basename(grants_path) + ".erb"
  owner node.ndb.user
  mode "0600"
  action :create
  variables({
              :my_ip => my_ip
            })
  notifies :install_grants, "ndb_mysql_basic[install]", :immediately
end


if node.ndb.enabled == "true"

  ndb_mysql_ndb "install" do
   action [:install_distributed_privileges, :install_memcached]
  end

  if node.kagent.enabled == "true"
    kagent_config service_name do
      service "NDB" # #{found_id}
      log_file "#{node.ndb.log_dir}/mysql_#{found_id}_out.log"
#      command "mysql"
#      command_user node.ndb.user 
#      command_script "#{node.ndb.scripts_dir}/mysql-client.sh"
    end
  end
end

ndb_start "mysqld" do
  action :start_if_not_running
end

