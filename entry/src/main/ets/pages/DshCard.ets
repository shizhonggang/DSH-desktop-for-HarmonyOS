/*
 * Copyright (c) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

/**
 * DSH service card — 2x2 mini.
 * Status dot + task title + one-line detail.
 */
// postCardAction is a global ArkUI function (declared in the ArkUI common
// runtime), not an import from @kit.FormKit.

function statusColor(status: string): string {
  switch (status) {
    case 'running': return '#4CAF50';
    case 'waiting': return '#FF9800';
    case 'error': return '#F44336';
    case 'done': return '#2196F3';
    default: return '#9E9E9E';
  }
}

@Entry
@Component
struct DshCard {
  @LocalStorageProp('taskStatus') taskStatus: string = 'idle';
  @LocalStorageProp('taskTitle') taskTitle: string = 'DSH';
  @LocalStorageProp('taskDetail') taskDetail: string = 'No active task';

  build() {
    Column({ space: 4 }) {
      Row() {
        Circle({ width: 8, height: 8 })
          .fill(statusColor(this.taskStatus))
          .margin({ right: 6 })
        Text(this.taskTitle)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor('#E0E0E0')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
      }
      .width('100%')

      Text(this.taskDetail)
        .fontSize(12)
        .fontColor('#B0B0B0')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
    }
    .width('100%')
    .height('100%')
    .padding(10)
    .backgroundColor('#1A1A2E')
    .borderRadius(12)
    .onClick(() => {
      postCardAction(this, {
        action: 'call',
        abilityName: 'EntryAbility',
        params: { method: 'onCardClick' }
      });
    })
  }
}
