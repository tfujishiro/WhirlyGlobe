/*
 *  MaplyQuadEarthTilesLayer.h
 *  WhirlyGlobe-MaplyComponent
 *
 *  Created by Steve Gifford on 5/13/13.
 *  Copyright 2011-2013 mousebird consulting
 *
 *  Licensed under the Apache License, Version 2.0 (the "License");
 *  you may not use this file except in compliance with the License.
 *  You may obtain a copy of the License at
 *  http://www.apache.org/licenses/LICENSE-2.0
 *
 *  Unless required by applicable law or agreed to in writing, software
 *  distributed under the License is distributed on an "AS IS" BASIS,
 *  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *  See the License for the specific language governing permissions and
 *  limitations under the License.
 *
 */

#import "MaplyViewControllerLayer.h"
#import "MaplyCoordinateSystem.h"
#import "MaplyTileSource.h"

/** This is a generic quad earth paging interface.  Hand it your coordinate system,
    bounds, and tile source object and it will page tiles for you.
    In general this is useful for feature data, such as vector features.  The image
    base maps have their own layers.
  */
@interface MaplyQuadEarthTilesLayer : MaplyViewControllerLayer

/// Construct with the coordinate system and the tile source
- (id)initWithCoordSystem:(MaplyCoordinateSystem *)coordSys tileSource:(NSObject<MaplyTileSource> *)tileSource;

/// Change the number of fetches allowed at once
@property (nonatomic,assign) int numSimultaneousFetches;

/// Whether or not we use skirts
@property (nonatomic,assign) bool handleEdges;

/// Whether or not we try to cover the poles
@property (nonatomic,assign) bool coverPoles;

/// Where we'll store cached images
@property (nonatomic) NSString *cacheDir;

@end
