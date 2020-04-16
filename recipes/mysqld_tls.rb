# This recipe is here to reconfigure the MySQL server to use TLS (if TLS is enabled)
# It cannot be done in the mysqld.rb recipe as we need MySQL to start Hopsworks to start the CA
# That's why this recipe is run after kagent::default (responsible for signing the certificates)
# and before the NN - the first service after Hopsworks which needs the database to be up and running 

if node['mysql']['tls'].casecmp?("true")
    # User certs must belong to ndb group to be able to rotate x509 material
    group node['ndb']['group'] do
        action :modify
        members node['kagent']['certs_user']
        append true
        not_if { node['install']['external_users'].casecmp("true") == 0 }
    end
  
    crypto_dir = x509_helper.get_crypto_dir(node['ndb']['user-home'])
    kagent_hopsify "Generate x.509" do
        user node['ndb']['user']
        group node['ndb']['group']
        crypto_directory crypto_dir
        action :generate_x509
        not_if { conda_helpers.is_upgrade || node["kagent"]["test"] == true }
    end

    service "mysqld" do
        provider Chef::Provider::Service::Systemd
        supports :restart => true, :stop => true, :start => true, :status => true
        action :nothing
    end
    
    found_id=find_service_id("mysqld", node['mysql']['id'])
    my_ip = my_private_ip()
    mysql_ip = node['mysql']['localhost'] == "true" ? "localhost" : my_ip
    certificate = "#{crypto_dir}/#{x509_helper.get_certificate_bundle_name(node['ndb']['user'])}"
    key = "#{crypto_dir}/#{x509_helper.get_private_key_pkcs1_name(node['ndb']['user'])}"
    hops_ca = "#{crypto_dir}/#{x509_helper.get_hops_ca_bundle_name()}"
    template "#{node['ndb']['root_dir']}/my.cnf" do
        source "my-ndb.cnf.erb"
        owner node['ndb']['user']
        group node['ndb']['group']
        mode "0640"
        action :create
        variables({
            :mysql_id => found_id,
            :my_ip => mysql_ip,
            :mysql_tls => true,
            :certificate => certificate,
            :key => key,
            :hops_ca => hops_ca
    })
    notifies :restart, resources(:service => "mysqld"), :immediately
    end
end