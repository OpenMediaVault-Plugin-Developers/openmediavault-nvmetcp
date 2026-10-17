#!/usr/bin/env python3
# test-salt-render.py — Offline rendering tests for the nvmetcp Salt state.
#
# Usage: python3 tests/test-salt-render.py [-v]
#
# Renders srv/salt/omv/deploy/nvmetcp/default.sls with Jinja2 and mocked
# salt[...] functions, then checks the generated /etc/nvmet/config.json
# dataset.  No root, OMV or Salt installation is required.
#
# Requirements:
#   - python3-jinja2, python3-yaml

import copy
import os
import unittest

import jinja2
import yaml

SLS = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..',
                   'srv', 'salt', 'omv', 'deploy', 'nvmetcp', 'default.sls')

LOCAL_IPV4 = ['127.0.0.1', '192.168.1.30']
LOCAL_IPV6 = ['::1', 'fd00::30']

BASE_CONFIG = {
    'enable': True,
    'auto_associate': True,
    'ports': {'port': []},
    'subsystems': {'subsystem': []},
    'associations': {'association': []},
}


def port(uuid, addr, nport=4420, adrfam='ipv4'):
    return {'uuid': uuid, 'addr': addr, 'nport': nport, 'adrfam': adrfam}


def subsystem(uuid, nqn, enable=True, allow_any_host=True, hosts=None,
              namespaces=None, serial='OMV00000001', model='OMV NVMe Target'):
    return {'uuid': uuid, 'nqn': nqn, 'enable': enable,
            'allow_any_host': allow_any_host, 'hosts': hosts or [],
            'namespaces': namespaces or [], 'serial': serial, 'model': model}


def render(config):
    """Render the SLS and return the parsed state document."""
    salt = {
        'omv_conf.get': lambda key: config,
        'network.ip_addrs': lambda **kw: list(LOCAL_IPV4),
        'network.ip_addrs6': lambda **kw: list(LOCAL_IPV6),
    }
    env = jinja2.Environment(
        extensions=['jinja2.ext.do', 'jinja2.ext.loopcontrols'])
    env.filters['to_bool'] = \
        lambda v: str(v).lower() in ('1', 'true', 'yes', 'y', 'on')
    env.filters['yaml'] = \
        lambda v: yaml.safe_dump(v, default_flow_style=True).strip()
    with open(SLS) as f:
        out = env.from_string(f.read()).render(salt=salt)
    return yaml.safe_load(out)


def dataset(config):
    doc = render(config)
    for item in doc['/etc/nvmet/config.json']['file.serialize']:
        if 'dataset' in item:
            return item['dataset']
    raise AssertionError('no dataset in rendered state')


def make_config(**kw):
    cfg = copy.deepcopy(BASE_CONFIG)
    if 'ports' in kw:
        cfg['ports']['port'] = kw.pop('ports')
    if 'subsystems' in kw:
        cfg['subsystems']['subsystem'] = kw.pop('subsystems')
    if 'associations' in kw:
        cfg['associations']['association'] = [
            {'portref': p, 'subsystemref': s} for p, s in kw.pop('associations')]
    cfg.update(kw)
    return cfg


class ServiceStateTest(unittest.TestCase):
    def test_disabled_stops_service(self):
        doc = render(make_config(enable=False))
        self.assertIn('nvmet_service_stopped', doc)
        self.assertNotIn('/etc/nvmet/config.json', doc)

    def test_enabled_runs_service(self):
        doc = render(make_config())
        self.assertIn('nvmet_service', doc)
        self.assertIn('/etc/nvmet/config.json', doc)

    def test_empty_config_renders(self):
        ds = dataset(make_config())
        self.assertEqual(ds, {'hosts': [], 'subsystems': [], 'ports': []})


class PortAddressTest(unittest.TestCase):
    def addr(self, p):
        return dataset(make_config(ports=[p]))['ports'][0]['addr']

    def test_local_ipv4_is_kept(self):
        a = self.addr(port('p1', '192.168.1.30'))
        self.assertEqual(a['traddr'], '192.168.1.30')
        self.assertEqual(a['adrfam'], 'ipv4')
        self.assertEqual(a['trtype'], 'tcp')

    def test_loopback_is_kept(self):
        self.assertEqual(self.addr(port('p1', '127.0.0.1'))['traddr'],
                         '127.0.0.1')

    def test_ipv4_wildcard_is_kept(self):
        self.assertEqual(self.addr(port('p1', '0.0.0.0'))['traddr'],
                         '0.0.0.0')

    def test_non_local_ipv4_falls_back_to_wildcard(self):
        self.assertEqual(self.addr(port('p1', '10.9.9.9'))['traddr'],
                         '0.0.0.0')

    def test_empty_addr_falls_back_to_wildcard(self):
        self.assertEqual(self.addr(port('p1', ''))['traddr'], '0.0.0.0')

    def test_ipv6_wildcard_is_kept(self):
        a = self.addr(port('p1', '::', adrfam='ipv6'))
        self.assertEqual(a['traddr'], '::')
        self.assertEqual(a['adrfam'], 'ipv6')

    def test_local_ipv6_is_kept(self):
        self.assertEqual(
            self.addr(port('p1', 'fd00::30', adrfam='ipv6'))['traddr'],
            'fd00::30')

    def test_non_local_ipv6_falls_back_to_ipv6_wildcard(self):
        self.assertEqual(
            self.addr(port('p1', 'fd00::99', adrfam='ipv6'))['traddr'], '::')

    def test_ipv4_addr_with_ipv6_family_falls_back(self):
        self.assertEqual(
            self.addr(port('p1', '192.168.1.30', adrfam='ipv6'))['traddr'],
            '::')

    def test_trsvcid_and_portid(self):
        ports = dataset(make_config(ports=[
            port('p1', '0.0.0.0', 4420), port('p2', '0.0.0.0', 4421)]))['ports']
        self.assertEqual([p['portid'] for p in ports], [1, 2])
        self.assertEqual([p['addr']['trsvcid'] for p in ports], [4420, 4421])


class SubsystemTest(unittest.TestCase):
    def test_disabled_subsystem_is_excluded(self):
        ds = dataset(make_config(subsystems=[
            subsystem('s1', 'nqn.2014-08.io.omv:a', enable=False),
            subsystem('s2', 'nqn.2014-08.io.omv:b')]))
        self.assertEqual([s['nqn'] for s in ds['subsystems']],
                         ['nqn.2014-08.io.omv:b'])

    def test_subsystem_without_nqn_is_excluded(self):
        ds = dataset(make_config(subsystems=[subsystem('s1', '')]))
        self.assertEqual(ds['subsystems'], [])

    def test_serial_and_model_are_used(self):
        ds = dataset(make_config(subsystems=[
            subsystem('s1', 'nqn.2014-08.io.omv:a', serial='SER123',
                      model='Model X')]))
        attr = ds['subsystems'][0]['attr']
        self.assertEqual(attr['serial'], 'SER123')
        self.assertEqual(attr['model'], 'Model X')
        self.assertEqual(attr['version'], '1.0')

    def test_empty_serial_and_model_fall_back(self):
        ds = dataset(make_config(subsystems=[
            subsystem('s1', 'nqn.2014-08.io.omv:a', serial='', model='')]))
        attr = ds['subsystems'][0]['attr']
        self.assertEqual(attr['serial'], '0000000000000001')
        self.assertEqual(attr['model'], 'OMV NVMe Target')

    def test_allow_any_host(self):
        ds = dataset(make_config(subsystems=[
            subsystem('s1', 'nqn.2014-08.io.omv:a', allow_any_host=True,
                      hosts=[{'hostnqn': 'nqn.2014-08.io.omv:h1'}])]))
        ss = ds['subsystems'][0]
        self.assertEqual(ss['attr']['allow_any_host'], '1')
        # Hosts are ignored when any host may connect.
        self.assertEqual(ss['allowed_hosts'], [])
        self.assertEqual(ds['hosts'], [])

    def test_allowed_hosts_are_deduplicated(self):
        h1 = {'hostnqn': 'nqn.2014-08.io.omv:h1'}
        h2 = {'hostnqn': 'nqn.2014-08.io.omv:h2'}
        ds = dataset(make_config(subsystems=[
            subsystem('s1', 'nqn.2014-08.io.omv:a', allow_any_host=False,
                      hosts=[h1, h1, h2]),
            subsystem('s2', 'nqn.2014-08.io.omv:b', allow_any_host=False,
                      hosts=[h2])]))
        self.assertEqual(ds['subsystems'][0]['attr']['allow_any_host'], '0')
        self.assertEqual(ds['subsystems'][0]['allowed_hosts'],
                         [h1['hostnqn'], h2['hostnqn']])
        self.assertEqual(ds['subsystems'][1]['allowed_hosts'],
                         [h2['hostnqn']])
        self.assertEqual(ds['hosts'],
                         [{'nqn': h1['hostnqn']}, {'nqn': h2['hostnqn']}])


class NamespaceTest(unittest.TestCase):
    def namespaces(self, nslist):
        ds = dataset(make_config(subsystems=[
            subsystem('s1', 'nqn.2014-08.io.omv:a', namespaces=nslist)]))
        return ds['subsystems'][0]['namespaces']

    def test_explicit_nsid_is_kept(self):
        ns = self.namespaces([{'path': '/dev/a', 'nsid': 5}])
        self.assertEqual(ns, [{'device': {'path': '/dev/a'}, 'enable': 1,
                               'nsid': 5}])

    def test_missing_nsids_are_assigned_sequentially(self):
        ns = self.namespaces([{'path': '/dev/a'}, {'path': '/dev/b'}])
        self.assertEqual([n['nsid'] for n in ns], [1, 2])

    def test_assigned_nsid_skips_used_ones(self):
        ns = self.namespaces([{'path': '/dev/a', 'nsid': 1},
                              {'path': '/dev/b', 'nsid': ''},
                              {'path': '/dev/c', 'nsid': 3},
                              {'path': '/dev/d', 'nsid': None}])
        self.assertEqual([n['nsid'] for n in ns], [1, 2, 3, 4])

    def test_every_namespace_has_unique_nsid(self):
        ns = self.namespaces([{'path': '/dev/%d' % i} for i in range(5)] +
                             [{'path': '/dev/x', 'nsid': 2}])
        nsids = [n['nsid'] for n in ns]
        self.assertEqual(len(nsids), len(set(nsids)))
        self.assertTrue(all(n >= 1 for n in nsids))

    def test_namespace_without_path_is_skipped(self):
        ns = self.namespaces([{'path': ''}, {'path': '/dev/a'}])
        self.assertEqual([n['device']['path'] for n in ns], ['/dev/a'])

    def test_uuid_and_nguid_are_passed_through(self):
        ns = self.namespaces([{'path': '/dev/a', 'uuid': 'u-1',
                               'nguid': 'g-1'}])
        self.assertEqual(ns[0]['device'],
                         {'path': '/dev/a', 'uuid': 'u-1', 'nguid': 'g-1'})

    def test_empty_uuid_and_nguid_are_omitted(self):
        ns = self.namespaces([{'path': '/dev/a', 'uuid': '', 'nguid': ''}])
        self.assertEqual(ns[0]['device'], {'path': '/dev/a'})

    def test_eui64_is_not_emitted(self):
        ns = self.namespaces([{'path': '/dev/a', 'eui64': '0011223344556677'}])
        self.assertNotIn('eui64', ns[0]['device'])

    def test_readonly_is_not_emitted(self):
        ns = self.namespaces([{'path': '/dev/a', 'readonly': True}])
        self.assertNotIn('readonly', ns[0])
        self.assertNotIn('readonly', ns[0]['device'])


class AssociationTest(unittest.TestCase):
    PORTS = [port('p1', '0.0.0.0', 4420), port('p2', '0.0.0.0', 4421)]
    SUBSYSTEMS = [subsystem('s1', 'nqn.2014-08.io.omv:a'),
                  subsystem('s2', 'nqn.2014-08.io.omv:b')]

    def port_subsystems(self, **kw):
        ds = dataset(make_config(ports=self.PORTS,
                                 subsystems=self.SUBSYSTEMS, **kw))
        return [p['subsystems'] for p in ds['ports']]

    def test_auto_associate_links_all(self):
        self.assertEqual(self.port_subsystems(),
                         [['nqn.2014-08.io.omv:a', 'nqn.2014-08.io.omv:b']] * 2)

    def test_auto_associate_off_links_nothing(self):
        self.assertEqual(self.port_subsystems(auto_associate=False),
                         [[], []])

    def test_explicit_association_overrides_auto_for_that_port(self):
        self.assertEqual(
            self.port_subsystems(associations=[('p1', 's2')]),
            [['nqn.2014-08.io.omv:b'],
             ['nqn.2014-08.io.omv:a', 'nqn.2014-08.io.omv:b']])

    def test_explicit_association_without_auto(self):
        self.assertEqual(
            self.port_subsystems(auto_associate=False,
                                 associations=[('p2', 's1'), ('p2', 's1')]),
            [[], ['nqn.2014-08.io.omv:a']])

    def test_association_to_disabled_subsystem_is_ignored(self):
        subs = [subsystem('s1', 'nqn.2014-08.io.omv:a', enable=False)]
        ds = dataset(make_config(ports=self.PORTS[:1], subsystems=subs,
                                 auto_associate=False,
                                 associations=[('p1', 's1')]))
        self.assertEqual(ds['ports'][0]['subsystems'], [])

    def test_dangling_association_is_ignored(self):
        self.assertEqual(
            self.port_subsystems(auto_associate=False,
                                 associations=[('p1', 'missing'),
                                               ('missing', 's1')]),
            [[], []])


if __name__ == '__main__':
    unittest.main()
