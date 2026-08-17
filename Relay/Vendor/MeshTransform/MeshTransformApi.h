//
//  MeshTransformApi.h
//  Relay — vendored from Telegram-iOS (GPL-2.0)
//
//  Source: submodules/TelegramUI/Components/MeshTransform/MeshTransformApi/
//          PublicHeaders/MeshTransformApi/MeshTransformApi.h
//
//  These structs are passed straight to CoreAnimation's private mesh-transform API
//  through `@convention(c)` function pointers, so they must be genuine C types —
//  Swift-declared structs are not Objective-C representable and cannot cross that
//  boundary. Hence the bridging header rather than a Swift translation.
//

#ifndef MeshTransformApi_h
#define MeshTransformApi_h

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

typedef struct MeshTransformMeshFace {
    unsigned int indices[4];
    float w[4];
} MeshTransformMeshFace;

typedef struct MeshTransformPoint3D {
    CGFloat x;
    CGFloat y;
    CGFloat z;
} MeshTransformPoint3D;

typedef struct MeshTransformMeshVertex {
    CGPoint from;
    MeshTransformPoint3D to;
} MeshTransformMeshVertex;

#endif /* MeshTransformApi_h */
