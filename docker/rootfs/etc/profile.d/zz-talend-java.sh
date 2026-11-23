# Java installed by the Talend install scripts (scripts/vm_*/install_*.sh).
# It lives in the persisted volume (/opt/talend/java), while the home folders do
# not: this file (part of the image) restores JAVA_HOME and PATH in every shell,
# even after the container is recreated. Loaded after profile.d/java.sh (image
# default Java 17), so it wins. Does nothing if the link does not exist.
if [ -x /opt/talend/java/default/bin/java ]; then
  JAVA_HOME=/opt/talend/java/default
  export JAVA_HOME
  case ":$PATH:" in
    *":$JAVA_HOME/bin:"*) ;;
    *) PATH="$JAVA_HOME/bin:$PATH"; export PATH ;;
  esac
fi
