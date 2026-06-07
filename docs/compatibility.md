# Compatibility

| Python package | Host | Protocol | Python | Reaper | Status |
|---|---|---|---|---|---|
| 0.2.x | 0.2.x | 1.1 | 3.11-3.12 | 7.x Windows | MMG v3 compatibility |
| 0.1.x | 0.1.x | 1.0 | 3.11-3.12 | 7.x Windows | Incubating |

The 0.2 client requires protocol 1.1. A 0.1 host fails explicitly during hello;
0.1 clients continue to use a matching 0.1 host.
The package, host, and protocol versions are independent.
