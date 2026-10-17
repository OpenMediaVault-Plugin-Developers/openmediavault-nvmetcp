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
    - mode: '0755'

{# Local addresses per family (include loopback) #}
{% set local_ips = {
  'ipv4': salt['network.ip_addrs'](include_loopback=True),
  'ipv6': salt['network.ip_addrs6'](include_loopback=True)
} %}
{% set wildcard = { 'ipv4': '0.0.0.0', 'ipv6': '::' } %}

{# ------------------------------ #
 # Ports list (validated traddr)  #
 # ------------------------------ #}
{% set ports_list = [] %}
{% set port_uuid_to_idx = {} %}
{% for p in (config.get('ports', {}).get('port', []) ) %}
  {% set portid = loop.index %}
  {% set addrfam = p.get('adrfam', 'ipv4') %}
  {% if addrfam not in wildcard %}{% set addrfam = 'ipv4' %}{% endif %}
  {% set requested = p.get('addr', '') | trim %}
  {# use the configured address if bindable, else listen on all addresses #}
  {% if requested and (requested == wildcard[addrfam] or requested in local_ips[addrfam]) %}
    {% set traddr = requested %}
  {% else %}
    {% set traddr = wildcard[addrfam] %}
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
  {% set used_nsids = [] %}
  {% for ns in (ss.get('namespaces') or []) %}
    {% set nsid = ns.get('nsid') | int(0) %}
    {% if nsid > 0 %}{% do used_nsids.append(nsid) %}{% endif %}
  {% endfor %}
  {% for ns in (ss.get('namespaces') or []) %}
    {% set path = ns.get('path', '') %}
    {% if not path %}{% continue %}{% endif %}

    {# nvmetcli skips namespaces without an nsid; assign the next free one #}
    {% set ns_id = namespace(value=(ns.get('nsid') | int(0))) %}
    {% if ns_id.value < 1 %}
      {% for i in range(1, used_nsids | length + 2) if i not in used_nsids %}
        {% if loop.first %}{% set ns_id.value = i %}{% do used_nsids.append(i) %}{% endif %}
      {% endfor %}
    {% endif %}
    {% set nsid = ns_id.value %}
    {% set ns_enable = 1 if (ns.get('enable', True)) else 0 %}

    {# the kernel only exposes device_path, device_uuid and device_nguid #}
    {% set dev = { 'path': path } %}
    {% if ns.get('uuid') %}{% do dev.update({'uuid': ns['uuid']}) %}{% endif %}
    {% if ns.get('nguid') %}{% do dev.update({'nguid': ns['nguid']}) %}{% endif %}

    {% set nsrec = { 'device': dev, 'enable': ns_enable, 'nsid': nsid } %}

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
    'attr': {
      'allow_any_host': allow_any,
      'serial': ss.get('serial') or '0000000000000001',
      'model': ss.get('model') or 'OMV NVMe Target',
      'version': '1.0'
    },
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
