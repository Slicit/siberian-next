// Registering a device, as a hook.
//
// Separated from the screen because it is the part with the rules: ask the
// operating system first, register only if the answer was yes, and never
// pretend the answer was yes. A screen that mixed the two would eventually
// register a token nobody agreed to.
//
// The import is static and that is safe: this file is only compiled into an
// app when the module's push requirement has been approved, and when it has
// not, the module falls back to a WebView and none of this is in the bundle.
import { useCallback, useEffect, useState } from "react";
import { Platform } from "react-native";
import * as Notifications from "expo-notifications";

// A notification that arrives while the app is open should still be seen.
// Without this the system swallows it, and the inbox gains a row nobody
// noticed, which reads as the push having failed.
Notifications.setNotificationHandler({
  handleNotification: async () => ({
    shouldShowAlert: true,
    shouldPlaySound: false,
    shouldSetBadge: true
  })
});

export function usePushRegistration(siberian) {
  const [state, setState] = useState({ status: "asking", detail: null });

  const register = useCallback(async () => {
    try {
      const existing = await Notifications.getPermissionsAsync();
      let granted = existing.granted;

      if (!granted && existing.canAskAgain) {
        const asked = await Notifications.requestPermissionsAsync();
        granted = asked.granted;
      }

      if (!granted) {
        // Not an error. Somebody said no, and the inbox still works: the
        // difference is that nothing will reach the tray.
        setState({ status: "declined", detail: "Notifications are turned off for this app." });
        return;
      }

      if (Platform.OS === "android") {
        // Android puts everything without a channel into a silent default one.
        await Notifications.setNotificationChannelAsync("default", {
          name: "Notifications",
          importance: Notifications.AndroidImportance.DEFAULT
        });
      }

      const { data: token } = await Notifications.getExpoPushTokenAsync();
      const response = await siberian.call("api/devices", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ token, platform: Platform.OS })
      });

      if (!response.ok) throw new Error(`the module answered ${response.status}`);
      setState({ status: "registered", detail: null });
    } catch (problem) {
      setState({ status: "failed", detail: problem.message });
    }
  }, [siberian]);

  useEffect(() => {
    register();
  }, [register]);

  return { ...state, retry: register };
}

// Something arrived while somebody was looking at the list.
export function useIncoming(onArrival) {
  useEffect(() => {
    const received = Notifications.addNotificationReceivedListener(onArrival);
    const tapped = Notifications.addNotificationResponseReceivedListener(onArrival);

    return () => {
      received.remove();
      tapped.remove();
    };
  }, [onArrival]);
}
