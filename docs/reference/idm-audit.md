# Reference audit

Reviewed the official home page and expanded feature page on 2026-11-09:

- https://www.internetdownloadmanager.com/
- https://www.internetdownloadmanager.com/features2.html
- https://www.internetdownloadmanager.com/support/segmentation.html
- https://www.internetdownloadmanager.com/support/idm-grabber/idm_grabber.html
- https://www.internetdownloadmanager.com/support/idm-scheduler/idm_scheduler.html

Official trial downloaded locally from `https://download.internetdownloadmanager.com/idman643build18.exe`.
SHA-256: `7346128fab42957b4254eabdb012bfdbd751e9069361e98a6916f26bb03d62ee`.
`file` identifies PE32 GUI Intel 80386, Windows. The executable is kept in the ignored `.artifacts/reference` directory and is never redistributed. There is no Windows/Wine runtime in this environment, so the original application's runtime behavior has not been tested.

Published features include accelerated dynamic segmentation, HTTP/HTTPS/FTP/MMS, recovery/resume, browser takeover and context menus, video panel, scheduled queues and periodic synchronization, categories, site spider, page-wide downloads, interface customization, multilingual UI, updater, hourly quota, antivirus hooks, proxy support, Basic/Negotiate/NTLM/Kerberos authentication, and drag/drop.

These are reference requirements, not evidence that Current implements them all. `docs/FEATURES.md` records actual implementation and verification. Proprietary source, algorithms, assets and extension code were not used.
