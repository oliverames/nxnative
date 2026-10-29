// iOS-only scene ownership. Events keep the existing front end's 0..3 values;
// connect/disconnect additionally maintain the opt-in shared-runtime registry.
#pragma once
#import <UIKit/UIKit.h>

int front_ios_external_enabled(void);
UIViewController *front_ios_external_root(UIWindowScene *scene);
void front_ios_external_disconnect(UIViewController *controller);
void front_ios_scene_event(UIWindowScene *scene, int event);
void front_ios_scene_changed(UIWindowScene *scene);
