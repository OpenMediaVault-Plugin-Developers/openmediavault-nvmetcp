<?php

/**
 * Copyright (C) 2025-2026 openmediavault plugin developers
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

require_once("openmediavault/functions.inc");

class OMVRpcServiceNvmetcp extends \OMV\Rpc\ServiceAbstract
{
    public function getName()
    {
        return 'nvmetcp';
    }

    public function initialize()
    {
        $this->registerMethod('getSettings');
        $this->registerMethod('setSettings');

        $this->registerMethod('listPorts');
        $this->registerMethod('getPort');
        $this->registerMethod('setPort');
        $this->registerMethod('deletePort');

        $this->registerMethod('listSubsystems');
        $this->registerMethod('getSubsystem');
        $this->registerMethod('setSubsystem');
        $this->registerMethod('deleteSubsystem');

        $this->registerMethod('listAssociations');
        $this->registerMethod('getAssociation');
        $this->registerMethod('setAssociation');
        $this->registerMethod('deleteAssociation');
        $this->registerMethod('enumeratePorts');
        $this->registerMethod('enumerateSubsystems');
    }

    public function getSettings($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Get configuration object
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get('conf.service.nvmetcp');
        // Remove useless properties from the object.
        $object->remove('ports');
        $object->remove('subsystems');
        $object->remove('associations');
        return $object->getAssoc();
    }

    public function setSettings($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.nvmetcp.setsettings');
        // Get the existing configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get('conf.service.nvmetcp');
        $object->setAssoc($params);
        // Set the configuration object.
        $db->set($object);
        // Remove useless properties from the object.
        $object->remove('ports');
        $object->remove('subsystems');
        $object->remove('associations');
        // Return the configuration object.
        return $object->getAssoc();
    }

    public function listPorts($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.common.getlist");
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $objects = $db->getAssoc("conf.service.nvmetcp.port");
        // Filter the result.
        return $this->applyFilter($objects, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir']);
    }

    public function getPort($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.common.objectuuid");
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        return $db->getAssoc("conf.service.nvmetcp.port", $params['uuid']);
    }

    public function setPort($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, 'rpc.nvmetcp.setport');
        // set to new uuid constant if none found
        $newuuid = \OMV\Environment::get('OMV_CONFIGOBJECT_NEW_UUID');
        if (empty($params['uuid'])) {
            $params['uuid'] = $newuuid;
        }
        // Prepare the configuration object.
        $object = new \OMV\Config\ConfigObject('conf.service.nvmetcp.port');
        $object->setAssoc($params);
        // Set the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $db->assertIsUnique($object, 'nport');
        $db->set($object);
        // Return the configuration object.
        return $object->getAssoc();
    }

    public function deletePort($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.common.objectuuid");
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.nvmetcp.port", $params['uuid']);
        // remove associations
        $rows = $db->getByFilter("conf.service.nvmetcp.association", [
            "operator" => "stringEquals",
            "arg0" => "portref",
            "arg1" => $params['uuid']
        ]);
        foreach ($rows as $row) {
            $db->delete($row);
        }
        // Delete the configuration object.
        $db->delete($object);
        // Return the deleted configuration object.
        return $object->getAssoc();
    }


    private function buildTargetNqn(string $name): string {
        $s = \OMV\Config\Database::getInstance()->getAssoc('conf.service.nvmetcp');
        $orgDomain = strtolower(trim((string)($s["org_domain"] ?? "")));
        $orgDate   = strtolower(trim((string)($s["org_date"] ?? "")));

        $orgDomain = preg_replace('~[^a-z0-9.-]+~', '', $orgDomain);
        $orgDomain = trim($orgDomain, '.-');
        if ($orgDomain === '') $orgDomain = 'io.omv';

        $orgDate = preg_replace('~[^0-9-]+~', '', $orgDate);
        if (!preg_match('~^[0-9]{4}-[0-1][0-9]$~', $orgDate)) $orgDate = '2014-08';

        $slug = strtolower(trim($name));
        $slug = preg_replace('~[^a-z0-9._-]+~', '-', $slug);
        $slug = trim($slug, '.-');
        if ($slug === '') $slug = 'subsystem';

        $nqn = sprintf('nqn.%s.%s:%s', $orgDate, $orgDomain, $slug);
        if (!$this->isValidNqn($nqn)) {
            throw new \OMV\Exception(gettext("Generated NQN failed validation."));
        }
        return $nqn;
    }

    private function isValidNqn(string $nqn): bool {
        if (strlen($nqn) > 223) return false;
        if (strpos($nqn, 'nqn.') !== 0) return false;
        $pattern1 = '~^nqn\.[0-9]{4}-[0-1][0-9]\.[a-z0-9.-]+:[a-z0-9._:-]+$~';
        if (preg_match($pattern1, $nqn)) return true;
        $pattern2 = '~^nqn\.[a-z0-9.-]+:[a-z0-9._:-]+$~';
        return (bool)preg_match($pattern2, $nqn);
    }

    private function asList($value): array {
        if (!is_array($value) || empty($value)) return [];
        return array_is_list($value) ? $value : [$value];
    }

    private function subsystemAssoc(\OMV\Config\ConfigObject $object): array {
        $assoc = $object->getAssoc();
        $assoc['hosts'] = $this->asList($assoc['hosts'] ?? []);
        $assoc['namespaces'] = $this->asList($assoc['namespaces'] ?? []);
        return $assoc;
    }

    // ---------- Subsystems ----------

    public function listSubsystems($params, $context)
    {
        // Validate the RPC caller context and params.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.common.getlist");

        $db = \OMV\Config\Database::getInstance();
        $objects = $db->get("conf.service.nvmetcp.subsystem");

        $objectsAssoc = [];
        foreach ($objects as $objectv) {
            // ----- Hosts summary -----
            $allowAny = (bool) $objectv->get("allow_any_host");
            if ($allowAny) {
                $hosttext = [gettext("Any host")];
            } else {
                $hosttext = [gettext("None")];
                $hosts = $this->asList($objectv->get("hosts"));
                $hostNqns = [];
                foreach ($hosts as $h) {
                    if ($h instanceof \OMV\Config\ConfigObject) {
                        $val = (string) $h->get("hostnqn");
                        if ($val !== "") $hostNqns[] = $val;
                    } elseif (is_array($h) && isset($h["hostnqn"]) && is_string($h["hostnqn"])) {
                        $val = trim($h["hostnqn"]);
                        if ($val !== "") $hostNqns[] = $val;
                    }
                }
                if (!empty($hostNqns)) {
                    $hosttext = $hostNqns;
                }
            }

            // ----- Namespaces summary -----
            $nstext = [gettext("None")];
            $namespaces = $this->asList($objectv->get("namespaces"));
            $nsParts = [];
            foreach ($namespaces as $ns) {
                // Support both ConfigObject rows and associative arrays
                if ($ns instanceof \OMV\Config\ConfigObject) {
                    $nsid = $ns->get("nsid");
                    $path = (string) $ns->get("path");
                } else {
                    $nsid = $ns["nsid"] ?? null;
                    $path = (string) ($ns["path"] ?? "");
                }
                if ($path === "") {
                    continue; // path is required; skip bad rows defensively
                }
                $label = "";
                if ($nsid !== null && $nsid !== "") {
                    // nsid is optional; only prefix if present
                    $label .= (int) $nsid . ":";
                }
                $label .= $path;
                $nsParts[] = $label;
            }
            if (!empty($nsParts)) {
                $nstext = $nsParts;
            }

            // Attach computed fields
            $assoc = $this->subsystemAssoc($objectv);
            $assoc['hostlist'] = $hosttext;
            $assoc['nslist'] = $nstext;

            $objectsAssoc[] = $assoc;
        }

        // Filter the result.
        return $this->applyFilter($objectsAssoc, $params["start"], $params["limit"],
            $params["sortfield"], $params["sortdir"]);
    }

    public function getSubsystem($params, $context) {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        // Validate the parameters of the RPC service method.
        $this->validateMethodParams($params, "rpc.common.objectuuid");
        // Get the configuration object.
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.nvmetcp.subsystem", $params['uuid']);
        // Return the configuration object.
        return $this->subsystemAssoc($object);
    }

    public function setSubsystem($params, $context) {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, 'rpc.nvmetcp.setsubsystem');
        // set to new uuid constant if none found
        if (empty($params['uuid'])) {
            $params['uuid'] = \OMV\Environment::get('OMV_CONFIGOBJECT_NEW_UUID');
        }
        // Generate the NQN if none was given.
        $nqn = trim((string)($params['nqn'] ?? ''));
        if ($nqn === '') {
            $nqn = $this->buildTargetNqn((string)($params['description'] ?? ''));
        }
        if (!$this->isValidNqn($nqn)) {
            throw new \OMV\Exception(gettext("Invalid NQN format."));
        }
        $params['nqn'] = $nqn;
        // nvmetcli requires an NSID for every namespace; assign the next
        // free one to namespaces that have none.
        $namespaces = $params['namespaces'] ?? [];
        $used = [];
        foreach ($namespaces as $ns) {
            if (isset($ns['nsid']) && $ns['nsid'] !== '') {
                $nsid = (int) $ns['nsid'];
                if (in_array($nsid, $used, true)) {
                    throw new \OMV\Exception(sprintf(
                        gettext("Duplicate NSID %d."), $nsid));
                }
                $used[] = $nsid;
            }
        }
        $next = 1;
        foreach ($namespaces as &$ns) {
            if (isset($ns['nsid']) && $ns['nsid'] !== '') {
                $ns['nsid'] = (int) $ns['nsid'];
                continue;
            }
            while (in_array($next, $used, true)) $next++;
            $ns['nsid'] = $next;
            $used[] = $next;
        }
        unset($ns);
        $params['namespaces'] = $namespaces;
        // Prepare the configuration object.
        $object = new \OMV\Config\ConfigObject('conf.service.nvmetcp.subsystem');
        $object->setAssoc($params);
        // Set the configuration object.
        $db = \OMV\Config\Database::getInstance();
        // Ensure NQN uniqueness across subsystems
        $db->assertIsUnique($object, 'nqn');
        $db->set($object);
        return $object->getAssoc();
    }

    public function deleteSubsystem($params, $context) {
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.common.objectuuid");
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.nvmetcp.subsystem", $params['uuid']);
        $rows = $db->getByFilter("conf.service.nvmetcp.association", [
            "operator" => "stringEquals",
            "arg0" => "subsystemref",
            "arg1" => $params['uuid']
        ]);
        foreach ($rows as $row) {
            $db->delete($row);
        }
        $db->delete($object);
        return $object->getAssoc();
    }

    public function listAssociations($params, $context) {
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.common.getlist");
        $db = \OMV\Config\Database::getInstance();
        $objects = $db->get("conf.service.nvmetcp.association");

        $objectsAssoc = [];
        foreach ($objects as $objectk => &$objectv) {
            $portdesc = gettext("n/a");
            if ($db->exists("conf.service.nvmetcp.port", [
                "operator" => "stringEquals",
                "arg0" => "uuid",
                "arg1" => $objectv->get("portref")
            ])) {
                $port = $db->get("conf.service.nvmetcp.port", $objectv->get("portref"));
                $portdesc = sprintf('%s:%s (%s)', $port->get("addr"),
                    $port->get("nport"), $port->get("adrfam"));
            }
            $objectv->add("portdesc", "string", $portdesc);

            $ssdesc = gettext("n/a");
            if ($db->exists("conf.service.nvmetcp.subsystem", [
                "operator" => "stringEquals",
                "arg0" => "uuid",
                "arg1" => $objectv->get("subsystemref")
            ])) {
                $ss = $db->get("conf.service.nvmetcp.subsystem", $objectv->get("subsystemref"));
                $ssdesc = sprintf('%s [%s] [%s]', $ss->get("nqn"),
                    $ss->get("model"), $ss->get("serial"));
            }
            $objectv->add("ssdesc", "string", $ssdesc);

            $objectsAssoc[] = $objectv->getAssoc();
        }
        return $this->applyFilter($objectsAssoc, $params['start'], $params['limit'],
            $params['sortfield'], $params['sortdir']);
    }

    public function getAssociation($params, $context) {
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.common.objectuuid");
        $db = \OMV\Config\Database::getInstance();
        return $db->getAssoc("conf.service.nvmetcp.association", $params['uuid']);
    }

    public function setAssociation($params, $context) {
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, 'rpc.nvmetcp.setassociation');

        $object = new \OMV\Config\ConfigObject('conf.service.nvmetcp.association');
        $object->setAssoc($params);

        $db = \OMV\Config\Database::getInstance();
        // Make sure the referenced objects exist.
        $db->get("conf.service.nvmetcp.port", $params['portref']);
        $db->get("conf.service.nvmetcp.subsystem", $params['subsystemref']);
        if (true === $object->isNew()) {
            // Ensure unique pair portref+subsystemref
            $siblings = $db->getByFilter("conf.service.nvmetcp.association", [
                "operator" => "and",
                "arg0" => [ "operator" => "stringEquals", "arg0" => "portref", "arg1" => $params['portref'] ],
                "arg1" => [ "operator" => "stringEquals", "arg0" => "subsystemref", "arg1" => $params['subsystemref'] ],
            ]);
            if (count($siblings) > 0) {
                throw new \OMV\Exception(gettext("Association already exists."));
            }
        }
        $db->set($object);
        return $object->getAssoc();
    }

    public function deleteAssociation($params, $context) {
        $this->validateMethodContext($context, ["role" => OMV_ROLE_ADMINISTRATOR]);
        $this->validateMethodParams($params, "rpc.common.objectuuid");
        $db = \OMV\Config\Database::getInstance();
        $object = $db->get("conf.service.nvmetcp.association", $params['uuid']);
        $db->delete($object);
        return $object->getAssoc();
    }

    public function enumeratePorts($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Get configuration data.
        $db = \OMV\Config\Database::getInstance();
        $objects = $db->get("conf.service.nvmetcp.port");
        $ports = [];
        foreach ($objects as $objectk => &$objectv) {
            $uuid = $objectv->get("uuid");
            $address = $objectv->get("addr");
            $port = $objectv->get("nport");
            $family = $objectv->get("adrfam");
            $ports[] = [
                'uuid' => $uuid,
                'desc' => sprintf('%s:%s (%s)', $address, $port, $family)
            ];
        }
        // Filter the result.
        return ($ports);
    }

    public function enumerateSubsystems($params, $context)
    {
        // Validate the RPC caller context.
        $this->validateMethodContext($context, ['role' => OMV_ROLE_ADMINISTRATOR]);
        // Get configuration data.
        $db = \OMV\Config\Database::getInstance();
        $objects = $db->get("conf.service.nvmetcp.subsystem");

        $subsystems = [];
        foreach ($objects as $obj) {
            $uuid = (string) $obj->get("uuid");
            $nqn = trim((string) $obj->get("nqn"));
            $enable = (bool) $obj->get("enable");
            if (!$enable) {
                continue;
            }

            // ----- Count namespaces -----
            $namespaces = $this->asList($obj->get("namespaces"));
            $nsCount = 0;
            foreach ($namespaces as $ns) {
                // Basic sanity: must have a path
                if ($ns instanceof \OMV\Config\ConfigObject) {
                    $path = (string) $ns->get("path");
                } elseif (is_array($ns)) {
                    $path = (string) ($ns['path'] ?? '');
                } else {
                    $path = '';
                }
                if ($path !== '') $nsCount++;
            }

            // ----- Count hosts (respect allow_any_host) -----
            $allowAny = (bool) $obj->get("allow_any_host");
            $hostCount = 0;
            if (!$allowAny) {
                $hosts = $this->asList($obj->get("hosts"));
                foreach ($hosts as $h) {
                    if ($h instanceof \OMV\Config\ConfigObject) {
                        $val = (string) $h->get("hostnqn");
                    } elseif (is_array($h)) {
                        $val = (string) ($h['hostnqn'] ?? '');
                    } else {
                        $val = '';
                    }
                    if ($val !== '') $hostCount++;
                }
            }

            // ----- Build display text -----
            $hostPart = $allowAny ? 'any host' : sprintf('%d host%s', $hostCount, $hostCount === 1 ? '' : 's');
            $desc = sprintf('%s — %d ns, %s', $nqn !== '' ? $nqn : $uuid, $nsCount, $hostPart);

            $subsystems[] = [
                'uuid' => $uuid,
                'desc' => $desc
            ];
        }

        // Sort by NQN (fallback to UUID), case-insensitive natural order.
        usort($subsystems, function ($a, $b) {
            return strnatcasecmp($a['desc'], $b['desc']);
        });

        return $subsystems;
    }
}
