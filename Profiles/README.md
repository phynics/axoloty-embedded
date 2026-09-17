# Profiles

A profile is one named `application x platform x transport` selection, built
and qualified as a unit.

A profile declares which Axoloty revision it is qualified against and carries
its own device evidence. Compatibility is per profile, never repository-wide.
The first profile will be ESP32-C6 + MQTT, migrated by
[#848](https://github.com/phynics/axoloty/issues/848).
