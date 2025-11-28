# This script simply exports a PYHTONHOME environment variable so that 
# python will behave expectedly. Instead of looking for modules in
# /var/pkg/installed_packages/python3 it will look in /usr for everything

[ -z "$PYTHONHOME" ] && export PYTHONHOME=/usr
