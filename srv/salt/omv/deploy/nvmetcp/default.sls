# @license   http://www.gnu.org/licenses/gpl.html GPL Version 3
# @author    OpenMediaVault Plugin Developers <plugins@omv-extras.org>
# @copyright Copyright (c) 2025-2026 openmediavault plugin developers

{% set config = salt['omv_conf.get']('conf.service.nvmetcp') %}

{% if config.enable | to_bool %}

# Ensure modules are present (safe no-ops if already loaded)
nvmet_module:
  kmod.present:
    - name: nvmet

nvmet_tcp_module:
  kmod.present:
    - name: nvmet_tcp
    - require:
      - kmod: nvmet_module

/etc/nvmet:
  file.directory:
    - user: root
    - group: root
    - mode: 0755

{# Local IPv4s (include loopback) #}
{% set local_ips = salt['network.ip_addrs'](include_loopback=True) %}

{# Prefer non-loopback RFC1918, else 127.0.0.1, else 0.0.0.0 #}
{% set preferred_ip = '0.0.0.0' %}
{% for ip in local_ips %}
  {% if ip != '127.0.0.1' and (ip.startswith('10.') or ip.startswith('192.168.') or ip.startswith('172.')) %}
    {% set preferred_ip = ip %}
    {% break %}
  {% endif %}
{% endfor %}
{% if preferred_ip == '0.0.0.0' and '127.0.0.1' in local_ips %}
  {% set preferred_ip = '127.0.0.1' %}
{% endif %}

{# ------------------------------ #
 # Ports list (validated traddr)  #
 # ------------------------------ #}
{% set ports_list = [] %}
{% set port_uuid_to_idx = {} %}
{% for p in (config.get('ports', {}).get('port', []) ) %}
  {% set portid = loop.index %}
  {% set addrfam = p.get('adrfam', 'ipv4') %}
  {% set requested = p.get('addr', '') %}
  {# choose a bindable address #}
  {% if not requested or (requested not in local_ips and requested not in ['0.0.0.0']) %}
    {% set traddr = preferred_ip %}
  {% else %}
    {% set traddr = requested %}
  {% endif %}
  {% set trsvcid = (p.get('nport', 4420) | int) %}

  {% set _ = ports_list.append({
      'portid': portid,
      'addr': {
        'trtype': 'tcp',
        'adrfam': addrfam,
        'traddr': traddr,
        'trsvcid': trsvcid
      },
      'referrals': [],
      'subsystems': []
  }) %}
  {% if p.get('uuid') %}
    {% set _ = port_uuid_to_idx.update({ p['uuid']: portid }) %}
  {% endif %}
{% endfor %}

{# -------------------------------------- #
 # Subsystems list + maps and host list   #
 # -------------------------------------- #}
{% set subsystems_list = [] %}
{% set subsys_uuid_to_nqn = {} %}
{% set host_nqns = [] %}  {# de-duped manually; only when allow_any == 0 #}

{% for ss in (config.get('subsystems', {}).get('subsystem', []) ) if ss.get('enable') %}
  {% set nqn = ss.get('nqn', '') %}
  {% if not nqn %}{% continue %}{% endif %}
  {% set allow_any = '1' if ss.get('allow_any_host', False) else '0' %}

  {# namespaces (list). Only include supported keys and correct types. #}
  {% set ns_out = [] %}
  {% for ns in (ss.get('namespaces') or []) %}
    {% set path = ns.get('path', '') %}
    {% if not path %}{% continue %}{% endif %}

    {% set nsid = ns.get('nsid') %}
    {% set ns_enable = 1 if (ns.get('enable', True)) else 0 %}

    {% set dev = { 'path': path } %}
    {% if ns.get('uuid') %}{% do dev.update({'uuid': ns['uuid']}) %}{% endif %}
    {% if ns.get('nguid') %}{% do dev.update({'nguid': ns['nguid']}) %}{% endif %}
    {% if ns.get('eui64') %}{% do dev.update({'eui64': ns['eui64']}) %}{% endif %}

    {% set nsrec = { 'device': dev, 'enable': ns_enable } %}
    {% if nsid is not none and nsid != '' %}{% do nsrec.update({'nsid': (nsid | int)}) %}{% endif %}

    {% do ns_out.append(nsrec) %}
  {% endfor %}

  {# allowed hosts (only when NOT allow-any) #}
  {% set allowed_hosts = [] %}
  {% if allow_any == '0' %}
    {% for h in (ss.get('hosts') or []) %}
      {% set val = (h.get('hostnqn') if h else '') %}
      {% if val %}
        {% if val not in allowed_hosts %}{% do allowed_hosts.append(val) %}{% endif %}
        {% if val not in host_nqns %}{% do host_nqns.append(val) %}{% endif %}
      {% endif %}
    {% endfor %}
  {% endif %}

  {% set ss_obj = {
    'nqn': nqn,
    'attr': { 'allow_any_host': allow_any, 'serial': '0000000000000001', 'version': '1.0' },
    'namespaces': ns_out,
    'allowed_hosts': allowed_hosts
  } %}
  {% do subsystems_list.append(ss_obj) %}

  {% if ss.get('uuid') %}
    {% do subsys_uuid_to_nqn.update({ ss['uuid']: nqn }) %}
  {% endif %}
{% endfor %}

{# ---------------------------- #
 # Top-level hosts array        #
 # (empty when all subsystems are allow-any)
 # ---------------------------- #}
{% set hosts_list = [] %}
{% for h in host_nqns %}
  {% do hosts_list.append({ 'nqn': h }) %}
{% endfor %}

{# ------------------------------------------------ #
 # Associate subsystems to ports (per-port list)    #
 # Prefer explicit associations by UUID; else auto  #
 # ------------------------------------------------ #}
{% set explicit_links = {} %} {# portid -> [nqn,...] #}
{% for a in (config.get('associations', {}).get('association', []) ) %}
  {% set pidx = port_uuid_to_idx.get(a.get('portref','')) %}
  {% set nqn  = subsys_uuid_to_nqn.get(a.get('subsystemref','')) %}
  {% if pidx and nqn %}
    {% if explicit_links.get(pidx) is none %}
      {% set _ = explicit_links.update({ pidx: [nqn] }) %}
    {% elif nqn not in explicit_links[pidx] %}
      {% do explicit_links[pidx].append(nqn) %}
    {% endif %}
  {% endif %}
{% endfor %}

{% set auto_assoc = config.get('auto_associate', True) %}

{# Precompute all subsystem NQNs as a list #}
{% set all_nqns = [] %}
{% for s in subsystems_list %}
  {% if s['nqn'] not in all_nqns %}{% do all_nqns.append(s['nqn']) %}{% endif %}
{% endfor %}

{% for p in ports_list %}
  {% set pidx = p['portid'] %}
  {% if explicit_links.get(pidx) %}
    {% set _ = p.update({'subsystems': explicit_links[pidx] }) %}
  {% elif auto_assoc and all_nqns %}
    {% set _ = p.update({'subsystems': all_nqns }) %}
  {% endif %}
{% endfor %}

{# ---------------------------- #
 # Final dataset (arrays only)  #
 # ---------------------------- #}
{% set dataset = {
  'hosts': hosts_list,
  'subsystems': subsystems_list,
  'ports': ports_list
} %}

/etc/nvmet/config.json:
  file.serialize:
    - formatter: json
    - dataset: {{ dataset | yaml }}
    - user: root
    - group: root
    - mode: '0644'
    - makedirs: True
    - require:
      - kmod: nvmet_tcp_module

nvmet_service:
  service.running:
    - name: nvmet
    - enable: True
    - watch:
      - file: /etc/nvmet/config.json
    - require:
      - kmod: nvmet_tcp_module

{% else %}

nvmet_service_stopped:
  service.dead:
    - name: nvmet
    - enable: False

{% endif %}
