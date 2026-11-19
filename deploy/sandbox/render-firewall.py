#!/usr/bin/env python3
"""Render an operator-owned network policy; no agent or market state here."""
import ipaddress
import json
from pathlib import Path
import sys


def render(config, template, node, bidder):
    if not node.isdecimal() or not bidder.isdecimal():
        raise ValueError('node and bidder uids must be decimal')
    if not isinstance(config, dict) or set(config) - {'mode', 'allow'}:
        raise ValueError('configuration is an object with mode and allow')
    mode = config.get('mode', 'public')
    rules = []
    if mode == 'restricted':
        allow = config.get('allow', [])
        if not isinstance(allow, list):
            raise ValueError('allow is a list of {cidr, tcp} entries')
        for entry in allow:
            if not isinstance(entry, dict) or set(entry) != {'cidr', 'tcp'}:
                raise ValueError('each allow entry has exactly cidr and tcp')
            network = ipaddress.ip_network(entry['cidr'], strict=False)
            ports = entry['tcp']
            if network.version != 4 or not isinstance(ports, list) or not ports:
                raise ValueError('allow entries need an IPv4 cidr and nonempty tcp port list')
            if any(type(p) is not int or not 1 <= p <= 65535 for p in ports):
                raise ValueError('tcp ports are integers from 1 to 65535')
            port_set = ', '.join(map(str, sorted(set(ports))))
            rules.append(f'    meta skuid {node} ip daddr {network} tcp dport {{ {port_set} }} counter accept')
        rules.append(f'    meta skuid {node} counter drop')
    elif mode != 'public':
        raise ValueError('mode must be public or restricted')
    return template.replace('PANTHEON_UID', node).replace('BIDDER_UID', bidder).replace('# NODE_EGRESS_RULES', '\n'.join(rules))


if __name__ == '__main__':
    try:
        config, template, node, bidder = sys.argv[1:]
        print(render(json.loads(Path(config).read_text()), Path(template).read_text(), node, bidder), end='')
    except (ValueError, TypeError, OSError) as error:
        sys.exit('pantheon firewall: ' + str(error))
