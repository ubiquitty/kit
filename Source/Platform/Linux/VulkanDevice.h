// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include "Platform/Linux/ImageExtent.h"

#include <memory>
#include <mutex>
#include <vulkan/vulkan.h>

namespace Ubiquitty::Linux {

/// The process's live Vulkan resource domain. Window targets and command pools
/// remain private; compatible glyph sheets may share this device and queue.
/// The weak registry releases the device when its last renderer or atlas dies.
class VulkanDevice {
public:
    VulkanDevice() = default;
    /// Waits for outstanding work and releases the device and instance.
    ~VulkanDevice();
    VulkanDevice(const VulkanDevice&) = delete;
    VulkanDevice& operator=(const VulkanDevice&) = delete;

    /// Acquires the process's live device or initializes its replacement.
    ///
    /// - Returns: A strong resource-domain owner, or null on Vulkan failure.
    [[nodiscard]] static std::shared_ptr<VulkanDevice> acquire();
    /// Returns the instance owning the selected physical device.
    [[nodiscard]] VkInstance instance() const { return m_instance; }
    /// Returns the physical device whose limits constrain shared resources.
    [[nodiscard]] VkPhysicalDevice physical() const { return m_physical; }
    /// Returns the logical device that owns the shared queue and glyph images.
    [[nodiscard]] VkDevice device() const { return m_device; }
    /// Returns the externally synchronized graphics queue.
    [[nodiscard]] VkQueue queue() const { return m_queue; }
    /// Returns the graphics queue family's index for private command pools.
    [[nodiscard]] std::uint32_t queueFamily() const { return m_queueFamily; }
    /// Returns the optional native-memory export entry point.
    [[nodiscard]] PFN_vkGetMemoryFdKHR getMemoryFileDescriptor() const { return m_getMemoryFileDescriptor; }
    /// Returns the device's checked frame-target extent limits.
    [[nodiscard]] ImageExtent maxTargetExtent() const { return m_maxTargetExtent; }
    /// Vulkan requires external synchronization of queue and shared atlas work.
    /// Recursive because a render may replace a lease or rebuild its atlas.
    [[nodiscard]] std::recursive_mutex& mutex() { return m_mutex; }

private:
    /// Selects a graphics device and initializes its queue and export support.
    ///
    /// - Returns: Whether every required Vulkan resource was created.
    bool initialize();
    std::recursive_mutex m_mutex;
    VkInstance m_instance = VK_NULL_HANDLE;
    VkPhysicalDevice m_physical = VK_NULL_HANDLE;
    VkDevice m_device = VK_NULL_HANDLE;
    VkQueue m_queue = VK_NULL_HANDLE;
    std::uint32_t m_queueFamily = 0;
    PFN_vkGetMemoryFdKHR m_getMemoryFileDescriptor = nullptr;
    ImageExtent m_maxTargetExtent;
};

}
