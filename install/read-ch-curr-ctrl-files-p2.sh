# Read controls once per boot while charging, with bounded concurrency.
ng_discover_controls current || :
ng_discover_controls voltage || :
ng_add_limit_switches || :
